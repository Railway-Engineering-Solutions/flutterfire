// ignore_for_file: require_trailing_commas
// Copyright 2025 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

/// A class representing a token that can be used to cancel a [getData] operation.
class CancelToken {
  bool _isCancelled = false;
  final Completer<void> _completer = Completer<void>();

  /// Whether the token has been cancelled.
  bool get isCancelled => _isCancelled;

  /// A [Future] that completes when the token is cancelled.
  Future<void> get onCancelled => _completer.future;

  /// Cancels the operation.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _completer.complete();
  }
}
