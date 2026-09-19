import 'dart:convert';

import 'package:antirkn_design_system/antirkn_design_system.dart';
import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/network/network_controller.dart';
import 'package:antirkn_manager/network/sample_inventory_reader.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/vpn/tt_certificates.dart';
import 'package:antirkn_manager/vpn/tt_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runner_support.dart';
import 'ssh_support.dart';
import 'tt_test.dart' as fixture;

class CertificateTransport extends FakeRunnerTransport {
  CertificateTransport(super.store);
  Map<String, dynamic>? planned;
  final certificates = <Map<String, Object?>>[];
  String planCode = 'ok';

  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    final action = request.json['action'];
    if (action == 'tt_certificate_plan' || action == 'tt_certificates') {
      requests.add(request);
      if (action == 'tt_certificate_plan') {
        planned =
            jsonDecode(request.json['payload'] as String)
                as Map<String, dynamic>;
      }
      return RunnerResponse.fromJson({
        'version': 1,
        'code': action == 'tt_certificate_plan' ? planCode : 'ok',
        'alive': true,
        'jobs': <Object?>[],
        'tt': action == 'tt_certificate_plan'
            ? {
                'fingerprint': 'f' * 64,
                'dns': {'addresses': planned!['expectedIps']},
              }
            : {'certificates': certificates, 'candidates': <Object?>[]},
      });
    }
    if (action == 'submit' && request.json['kind'] == 'tt_certificate') {
      final p = jsonDecode(request.json['payload'] as String) as Map;
      certificates.add({'id': p['id'], 'domain': p['domain']});
      job = runnerJob(
        request.id!,
        kind: 'tt_certificate',
        count: 4,
        progress: 4,
        status: 'succeeded',
      );
    }
    return super.request(request, cancellation, sudoPassword: sudoPassword);
  }
}

void main() {
  for (final language in ['ru', 'en']) {
    testWidgets(
      'Endpoint issues SNI certificate without losing draft, then exports listening port $language',
      (tester) async {
        tester.view.physicalSize = const Size(700, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = MemoryRunnerJournal();
        final remote = CertificateTransport(store);
        final runner = RunnerController(
          serverId: 'fixture',
          transport: () => remote,
          identity: () => 'fixture|key',
          password: () => null,
          accessFailure: (_) {},
          store: store,
        );
        final network = NetworkController(reader: SampleInventoryReader());
        addTearDown(network.dispose);
        await tester.runAsync(network.load);
        await runner.refresh(prepare: true);
        TrustTunnelEndpoint? result;
        late AppLocalizations l;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: AppTheme.create(Brightness.light),
            home: Builder(
              builder: (context) {
                l = AppLocalizations.of(context);
                return Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await showDialog<TrustTunnelEndpoint>(
                        context: context,
                        builder: (_) => ManagedTtDialog(
                          serverId: 'fixture',
                          spec: {
                            ...fixture.spec(),
                            'certificateId': '',
                            'listen': language == 'ru'
                                ? '0.0.0.0'
                                : '203.0.113.1',
                          },
                          runner: runner,
                          picker: FakeKeyPicker(),
                          network: network,
                          motion: MotionPreference.off,
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                );
              },
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tt-endpoint')), findsNothing);
        expect(find.byKey(const ValueKey('tt-externalPort')), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('tt-name')),
          'Preserved draft',
        );
        await tester.enterText(find.byKey(const ValueKey('tt-port')), '8443');
        final issue = find.byKey(const ValueKey('tt-issue-certificate'));
        await tester.ensureVisible(issue);
        await tester.tap(issue);
        await tester.pumpAndSettle();
        final dialog = find.byType(TtCertificateDialog);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('tt-certificate-domain')),
              )
              .controller!
              .text,
          'vpn.example.com',
        );
        for (final key in ['listen', 'expectedIps', 'email']) {
          expect(find.byKey(ValueKey('tt-certificate-$key')), findsNothing);
        }
        remote.planCode = 'tt_dns_mismatch';
        await tester.tap(
          find.descendant(of: dialog, matching: find.text(l.vpnSave)),
        );
        await tester.pumpAndSettle();
        expect(remote.submissions, 0);
        expect(find.text(l.ttDnsMismatch), findsOneWidget);
        remote.planCode = 'ok';
        await tester.tap(
          find.descendant(of: dialog, matching: find.text(l.vpnSave)),
        );
        await tester.pumpAndSettle();
        expect(remote.planned!['mode'], 'acme');
        if (language == 'en') {
          expect(remote.planned!['expectedIps'], contains('203.0.113.1'));
        }
        expect(remote.planned!['expectedIps'], contains('203.0.113.20'));
        expect(
          remote.planned!['listen'],
          language == 'ru' ? '0.0.0.0' : '203.0.113.1',
        );
        expect(remote.planned!['autoDetectIps'], isTrue);
        expect(remote.planned!['email'], '');
        expect(find.text(l.vpnApply), findsNothing);
        expect(find.byType(TtCertificateDialog), findsNothing);
        expect(remote.submissions, 1);
        expect(remote.submitWithoutPersistence, isFalse);
        final regen = find.byKey(const ValueKey('tt-regenerate-passwords'));
        await tester.ensureVisible(regen);
        expect(find.text(l.vpnDeleteHelp), findsNothing);
        expect(find.text(l.ttPasswordsAutomatic), findsOneWidget);
        if (language == 'ru') {
          await tester.tap(regen);
          await tester.pumpAndSettle();
          expect(find.text(l.ttPasswordsRegenerated), findsOneWidget);
        }
        await tester.tap(find.text(l.vpnSave));
        await tester.pumpAndSettle();
        expect(result!.spec['certificateId'], remote.certificates.single['id']);
        expect(result!.name, 'Preserved draft');
        expect(result!.spec['port'], 8443);
        expect(result!.spec['externalPort'], 8443);
        expect(result!.spec['endpoint'], 'vpn.example.com');
        expect(result!.spec['rotation'], language == 'ru' ? 1 : 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        runner.dispose();
      },
    );
  }
}
