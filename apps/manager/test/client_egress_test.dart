import 'dart:convert';

import 'package:antirkn_domain/antirkn_domain.dart';
import 'package:antirkn_manager/l10n/app_localizations.dart';
import 'package:antirkn_manager/runner/runner_controller.dart';
import 'package:antirkn_manager/ssh/client_egress_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runner_support.dart';

class EgressTransport extends FakeRunnerTransport {
  EgressTransport(super.store);
  String planCode = 'ok';
  @override
  Future<RunnerResponse> request(
    RunnerRequest request,
    CancellationToken cancellation, {
    String? sudoPassword,
  }) async {
    if ((request.json['action'] as String).startsWith('egress_')) {
      requests.add(request);
      return RunnerResponse.fromJson({
        'version': 1,
        'code': request.json['action'] == 'egress_plan' ? planCode : 'ok',
        'alive': true,
        'jobs': <Object?>[],
        'egress': request.json['action'] == 'egress_plan'
            ? {'fingerprint': 'e' * 64}
            : {'enabled': false, 'observedHash': 'f' * 64},
      });
    }
    return super.request(request, cancellation, sudoPassword: sudoPassword);
  }
}

void main() {
  late MemoryRunnerJournal store;
  late EgressTransport remote;
  late RunnerController c;
  setUp(() {
    store = MemoryRunnerJournal();
    remote = EgressTransport(store);
    c = RunnerController(
      serverId: 'fixture',
      transport: () => remote,
      identity: () => 'fixture|key',
      password: () => null,
      accessFailure: (_) {},
      store: store,
    );
  });
  tearDown(() => c.dispose());

  Future<void> ready() async {
    await c.prepareInstall();
    await c.applyInstall();
    remote.recoveredAccess = {
      'id': 'a' * 32,
      'port': 2053,
      'basePath': '/',
      'username': 'antirkn',
      'password': 'A' * 43,
      'panelVersion': '3.7.0',
      'xrayVersion': '26.7.28',
    };
    await c.discoverPanel();
  }

  test(
    'egress intent is durable before submit; lost reply keeps its ID',
    () async {
      await ready();
      remote.loseSubmitResponse = true;
      await c.applyEgress(enabled: true, uri: 'vless://fixture');
      expect(remote.submitWithoutPersistence, isFalse);
      expect(remote.submissions, 1);
      expect(c.pending?.json['kind'], 'egress_apply');
      final id = c.pending!.id;
      remote.loseSubmitResponse = false;
      await c.refresh();
      expect(c.selected?.id, id);
      expect(remote.submissions, 1);
      final journal = jsonDecode(store.value!) as Map;
      expect(journal['egress']['observedHash'], 'f' * 64);
    },
  );

  test('a conflicting plan never submits a server mutation', () async {
    await ready();
    remote.planCode = 'egress_conflict';
    expect(await c.applyEgress(enabled: true, uri: 'vless://fixture'), isFalse);
    expect(c.responseCode, 'egress_conflict');
    expect(remote.submissions, 0);
    expect(c.pending, isNull);
  });

  test(
    'saved public endpoint and NAT port take precedence over bind and SSH',
    () {
      final resource = VlessInbound(
        serverId: 'exit',
        spec: {
          ...VlessInbound.defaults(),
          'listen': '10.0.0.2',
          'port': 443,
          'endpoint': 'vpn.example',
          'externalPort': 2443,
          'sni': 'example.com',
          'target': 'example.com:443',
        },
      );
      expect(
        clientEgressDestination(
          row: {'listen': '10.0.0.2', 'port': 443},
          sshHost: 'ssh.example',
          resource: resource,
        ),
        (host: 'vpn.example', port: 2443),
      );
    },
  );

  test(
    'concrete IPv6 listener is retained for the inter-server connection',
    () {
      expect(
        clientEgressDestination(
          row: {'listen': '2001:db8::2', 'port': 8443},
          sshHost: 'ssh.example',
        ),
        (host: '2001:db8::2', port: 8443),
      );
    },
  );

  test(
    'wildcard and local-only listeners fall back to the saved server host',
    () {
      for (final listen in [
        '',
        '0.0.0.0',
        '::',
        '127.0.0.1',
        '::1',
        'fe80::1',
      ]) {
        expect(
          clientEgressDestination(
            row: {'listen': listen, 'port': 8443},
            sshHost: 'ssh.example',
          ),
          (host: 'ssh.example', port: 8443),
          reason: listen,
        );
      }
    },
  );

  for (final locale in ['ru', 'en']) {
    testWidgets(
      'egress form fits narrow screen, validates and cancels without effects $locale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        c.egress = {'enabled': false, 'observedHash': 'a' * 64};
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ClientEgressForm(controller: c),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byKey(const ValueKey('client-egress-uri')),
          'https://invalid.example',
        );
        await tester.tap(find.byKey(const ValueKey('client-egress-apply')));
        await tester.pumpAndSettle();
        expect(remote.submissions, 0);
        expect(find.byType(ClientEgressForm), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(locale == 'ru' ? 'Отмена' : 'Cancel').last);
        await tester.pumpAndSettle();
        expect(find.byType(ClientEgressForm), findsNothing);
        expect(remote.requests, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
