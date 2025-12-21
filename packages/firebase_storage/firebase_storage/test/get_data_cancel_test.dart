// ignore_for_file: require_trailing_commas
// Copyright 2025 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_storage_platform_interface/firebase_storage_platform_interface.dart';
import 'package:firebase_storage_platform_interface/src/method_channel/method_channel_firebase_storage.dart';
import 'package:firebase_storage_platform_interface/src/method_channel/method_channel_reference.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';

import 'mock.dart';

void main() {
  setupFirebaseStorageMocks();

  group('getData() with CancelToken', () {
    late FirebaseStorage storage;
    late FirebaseStoragePlatform storagePlatform;
    MockReferencePlatform mockReference = MockReferencePlatform();

    setUpAll(() async {
      FirebaseStoragePlatform.instance = kMockStoragePlatform;
      await Firebase.initializeApp();
      storage = FirebaseStorage.instance;
      storagePlatform = MethodChannelFirebaseStorage(
          app: storage.app, bucket: storage.bucket);
      when(kMockStoragePlatform.ref(any)).thenReturn(mockReference);
    });

    test('successfully downloads data when not cancelled', () async {
      final testData = Uint8List.fromList([1, 2, 3]);
      final cancelToken = CancelToken();

      when(mockReference.getData(10485760, cancelToken))
          .thenAnswer((_) async => testData);

      final result =
          await storage.ref('test.png').getData(10485760, cancelToken);
      expect(result, testData);
    });

    test('throws FirebaseException with canceled code when already cancelled',
        () async {
      final cancelToken = CancelToken()..cancel();

      final realDelegate = MethodChannelReference(storagePlatform, 'test.png');

      expect(
        () => realDelegate.getData(10485760, cancelToken),
        throwsA(
            isA<FirebaseException>().having((e) => e.code, 'code', 'canceled')),
      );
    });

    test('cancels ongoing download when token is cancelled', () async {
      final cancelToken = CancelToken();
      final streamController = StreamController<Uint8List>();

      final delegate = TestMethodChannelReference(
          storagePlatform, 'test.png', streamController.stream);

      final future = delegate.getData(10485760, cancelToken);

      // Ensure the listener is active
      expect(streamController.hasListener, isTrue);

      // Emit some data
      streamController.add(Uint8List.fromList([1, 2]));

      // Cancel the token
      cancelToken.cancel();

      expect(
        () => future,
        throwsA(
            isA<FirebaseException>().having((e) => e.code, 'code', 'canceled')),
      );

      // Give it a bit of time to cancel the subscription
      await Future.delayed(Duration.zero);
      expect(streamController.hasListener, isFalse);
    });
  });
}

class TestMethodChannelReference extends MethodChannelReference {
  TestMethodChannelReference(
      FirebaseStoragePlatform storage, String path, this.mockStream)
      : super(storage, path);
  final Stream<Uint8List> mockStream;

  @override
  Stream<Uint8List> streamData(int maxSize) => mockStream;
}
