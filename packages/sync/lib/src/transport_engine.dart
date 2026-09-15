import 'dart:typed_data';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:cryptography/cryptography.dart';

final class SyncTransportResult {
  const SyncTransportResult({
    required this.uploaded,
    required this.staged,
    required this.downloadCaughtUp,
  });
  final int uploaded, staged;

  /// Only the downloaded change-log boundary; says nothing about device trust
  /// or application of the staged objects, nor completion of all uploads.
  final bool downloadCaughtUp;
}

/// Bounded foreground cycle. The caller schedules retry/backoff and obtains
/// consent/OAuth; this class cannot execute server jobs or merge cloud data.
final class SyncTransportEngine {
  SyncTransportEngine({
    required this.remote,
    required this.journal,
    required this.packets,
    required this.changes,
  });
  final SyncRemoteStore remote;
  final SyncTransportJournal journal;
  final SyncPacketStore packets;
  final ChangeJournalStore changes;
  bool _running = false;

  Future<SyncTransportResult> exchange({
    int uploadLimit = 20,
    int downloadPageLimit = 10,
    SyncCancellation? cancellation,
  }) async {
    if (_running) throw const SyncTransportFailure(SyncTransportIssue.changed);
    if (uploadLimit < 0 ||
        uploadLimit > 100 ||
        downloadPageLimit < 1 ||
        downloadPageLimit > 100) {
      throw ArgumentError('transport_limits');
    }
    _running = true;
    final cancel = cancellation ?? SyncCancellation();
    try {
      cancel.check();
      final identity = await changes.readWorkspaceIdentity();
      if (identity.workspaceId != journal.workspaceId ||
          identity.deviceId != journal.deviceId ||
          remote.accountKey != journal.accountKey) {
        throw const SyncTransportFailure(SyncTransportIssue.changed);
      }
      var uploaded = 0;
      if (uploadLimit > 0) {
        for (final packet in await packets.preparePendingPackets(
          limit: uploadLimit,
        )) {
          cancel.check();
          final digest = await _digest(packet.bytes);
          var receipt = await journal.readUpload(packet.changeId);
          if (receipt == null) {
            final fileId = await remote.generateFileId();
            cancel.check();
            receipt = await journal.reserveUpload(
              SyncUploadReceipt(
                changeId: packet.changeId,
                fileId: fileId,
                digest: digest,
                size: packet.bytes.length,
              ),
            );
          }
          if (receipt.digest != digest || receipt.size != packet.bytes.length) {
            throw const SyncTransportFailure(SyncTransportIssue.conflict);
          }
          if (!receipt.confirmed) {
            await _deliver(receipt, packet.bytes, cancel);
            cancel.check();
            await journal.confirmUpload(receipt);
          }
          // Crash between receipt and ack reuses the receipt. It never chooses
          // a new remote ID or acknowledges any later local revision.
          cancel.check();
          await changes.acknowledgeChanges([packet.changeId]);
          uploaded++;
        }
      }
      var cursor = await journal.readCursor();
      if (cursor.startToken == null) {
        final start = await remote.getStartPageToken();
        cancel.check();
        await journal.saveCursor(
          SyncTransportCursor(startToken: start),
          expectedRevision: cursor.revision,
        );
        cursor = await journal.readCursor();
      }
      var staged = 0, caughtUp = false;
      for (var i = 0; i < downloadPageLimit; i++) {
        cancel.check();
        SyncRemotePage page;
        try {
          page = cursor.listing
              ? await remote.listFiles(pageToken: cursor.pageToken)
              : await remote.listChanges(cursor.startToken!);
        } on SyncTransportFailure catch (error) {
          if (error.issue != SyncTransportIssue.invalidCursor) rethrow;
          // Start a fresh full scan; keep every staged object and upload receipt.
          final start = await remote.getStartPageToken();
          cancel.check();
          await journal.saveCursor(
            SyncTransportCursor(startToken: start),
            expectedRevision: cursor.revision,
          );
          return SyncTransportResult(
            uploaded: uploaded,
            staged: staged,
            downloadCaughtUp: false,
          );
        }
        for (final file in page.files) {
          cancel.check();
          if (!file.packet && !file.removed) continue;
          Uint8List bytes;
          var removed = file.removed;
          if (removed) {
            bytes = Uint8List(0);
          } else {
            try {
              bytes = await remote.download(file.id);
            } on SyncTransportFailure catch (error) {
              if (error.issue != SyncTransportIssue.notFound) rethrow;
              // Deleted between list and download. Keep an observation, never
              // delete workspace entities or silently claim the data arrived.
              removed = true;
              bytes = Uint8List(0);
            }
            if (!removed && bytes.length != file.size) {
              throw const SyncTransportFailure(SyncTransportIssue.conflict);
            }
          }
          cancel.check();
          await journal.stageObject(
            StagedSyncObject(
              fileId: file.id,
              version: file.version,
              digest: await _digest(bytes),
              bytes: bytes,
              removed: removed,
            ),
          );
          staged++;
        }
        cancel.check();
        final next = page.nextPageToken;
        if (next != null &&
            next == (cursor.listing ? cursor.pageToken : cursor.startToken)) {
          throw const SyncTransportFailure(SyncTransportIssue.invalid);
        }
        caughtUp = !cursor.listing && next == null;
        if (caughtUp && page.newStartPageToken == null) {
          throw const SyncTransportFailure(SyncTransportIssue.invalid);
        }
        await journal.saveCursor(
          SyncTransportCursor(
            startToken: cursor.listing
                ? cursor.startToken
                : next ?? page.newStartPageToken,
            listing: cursor.listing && next != null,
            pageToken: cursor.listing ? next : null,
            lastDownloadAt: caughtUp
                ? DateTime.now().toUtc()
                : cursor.lastDownloadAt,
          ),
          expectedRevision: cursor.revision,
        );
        cursor = await journal.readCursor();
        if (caughtUp) break;
      }
      return SyncTransportResult(
        uploaded: uploaded,
        staged: staged,
        downloadCaughtUp: caughtUp,
      );
    } finally {
      _running = false;
    }
  }

  Future<void> _deliver(
    SyncUploadReceipt receipt,
    Uint8List bytes,
    SyncCancellation cancel,
  ) async {
    final name = '$syncTransportNamePrefix${receipt.digest}';
    var exists = false;
    try {
      await _verifyReceipt(receipt, name);
      exists = true;
    } on SyncTransportFailure catch (error) {
      if (error.issue != SyncTransportIssue.notFound) rethrow;
    }
    cancel.check();
    if (exists) return;
    try {
      await remote.createPacket(receipt.fileId, name, bytes);
    } on SyncTransportFailure catch (error) {
      if (error.issue != SyncTransportIssue.conflict) rethrow;
      // 409 is not proof that the intended bytes were uploaded.
    }
    cancel.check();
    await _verifyReceipt(receipt, name);
  }

  Future<void> _verifyReceipt(SyncUploadReceipt receipt, String name) async {
    final file = await remote.getFile(receipt.fileId);
    if (!file.packet ||
        file.removed ||
        file.name != name ||
        file.id != receipt.fileId ||
        file.size != receipt.size) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
    if (await _digest(await remote.download(receipt.fileId)) !=
        receipt.digest) {
      throw const SyncTransportFailure(SyncTransportIssue.conflict);
    }
  }
}

Future<String> _digest(Uint8List bytes) async => (await Sha256().hash(
  bytes,
)).bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
