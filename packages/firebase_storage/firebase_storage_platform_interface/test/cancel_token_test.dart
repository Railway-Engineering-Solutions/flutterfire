// ignore_for_file: require_trailing_commas
// Copyright 2025 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:firebase_storage_platform_interface/firebase_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CancelToken', () {
    test('initial state is not cancelled', () {
      final token = CancelToken();
      expect(token.isCancelled, isFalse);
    });

    test('cancel() sets isCancelled to true', () {
      final token = CancelToken();
      token.cancel();
      expect(token.isCancelled, isTrue);
    });

    test('onCancelled completes when cancel() is called', () async {
      final token = CancelToken();
      bool completed = false;
      token.onCancelled.then((_) => completed = true);

      expect(completed, isFalse);
      token.cancel();
      await Future.microtask(() {});
      expect(completed, isTrue);
    });

    test('cancel() multiple times is safe', () {
      final token = CancelToken();
      token.cancel();
      token.cancel();
      expect(token.isCancelled, isTrue);
    });
  });
}
