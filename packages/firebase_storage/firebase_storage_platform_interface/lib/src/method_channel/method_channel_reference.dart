// ignore_for_file: require_trailing_commas
// Copyright 2020, the Chromium project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';

import '../../firebase_storage_platform_interface.dart';
import '../pigeon/messages.pigeon.dart';
import 'method_channel_firebase_storage.dart';
import 'method_channel_list_result.dart';
import 'method_channel_task.dart';
import 'utils/exception.dart';

/// An implementation of [ReferencePlatform] that uses [MethodChannel] to
/// communicate with Firebase plugins.
class MethodChannelReference extends ReferencePlatform {
  /// Creates a [ReferencePlatform] that is implemented using [MethodChannel].
  MethodChannelReference(FirebaseStoragePlatform storage, String path)
      : super(storage, path);

  /// FirebaseApp pigeon instance
  PigeonStorageFirebaseApp get pigeonFirebaseApp {
    return PigeonStorageFirebaseApp(
      appName: storage.app.name,
      bucket: storage.bucket,
    );
  }

  /// Default of FirebaseReference pigeon instance
  PigeonStorageReference get pigeonReference {
    return PigeonStorageReference(
      bucket: storage.bucket,
      fullPath: fullPath,
      name: name,
    );
  }

  @override
  Future<void> delete() async {
    try {
      await MethodChannelFirebaseStorage.pigeonChannel
          .referenceDelete(pigeonFirebaseApp, pigeonReference);
    } catch (e, stack) {
      convertPlatformException(e, stack);
    }
  }

  @override
  Future<String> getDownloadURL() async {
    try {
      String url = await MethodChannelFirebaseStorage.pigeonChannel
          .referenceGetDownloadURL(pigeonFirebaseApp, pigeonReference);
      return url;
    } catch (e, stack) {
      convertPlatformException(e, stack);
    }
  }

  /// Convert a [PigeonFullMetaData] to [FullMetadata]
  static FullMetadata convertMetadata(PigeonFullMetaData pigeonMetadata) {
    Map<String, dynamic> _metadata = <String, dynamic>{};
    pigeonMetadata.metadata?.forEach((key, value) {
      if (key != null) {
        _metadata[key] = value;
      }
    });
    return FullMetadata(_metadata);
  }

  @override
  Future<FullMetadata> getMetadata() async {
    try {
      PigeonFullMetaData metaData = await MethodChannelFirebaseStorage
          .pigeonChannel
          .referenceGetMetaData(pigeonFirebaseApp, pigeonReference);
      return convertMetadata(metaData);
    } catch (e, stack) {
      convertPlatformException(e, stack);
    }
  }

  /// Convert a [ListOptions] to [PigeonListOptions]
  static PigeonListOptions convertOptions(ListOptions? options) {
    if (options == null) {
      return PigeonListOptions(maxResults: 1000);
    }
    return PigeonListOptions(
      maxResults: options.maxResults ?? 1000,
      pageToken: options.pageToken,
    );
  }

  /// Convert a [PigeonListResult] to [ListResultPlatform]
  ListResultPlatform convertListReference(
      PigeonListResult pigeonReferenceList) {
    List<String> referencePaths = [];
    for (final reference in pigeonReferenceList.items) {
      referencePaths.add(reference!.fullPath);
    }
    List<String> prefixPaths = [];
    for (final prefix in pigeonReferenceList.prefixs) {
      prefixPaths.add(prefix!.fullPath);
    }
    return MethodChannelListResult(
      storage,
      nextPageToken: pigeonReferenceList.pageToken,
      items: referencePaths,
      prefixes: prefixPaths,
    );
  }

  @override
  Future<ListResultPlatform> list([ListOptions? options]) async {
    try {
      PigeonListOptions pigeonOptions = convertOptions(options);
      PigeonListResult pigeonReferenceList = await MethodChannelFirebaseStorage
          .pigeonChannel
          .referenceList(pigeonFirebaseApp, pigeonReference, pigeonOptions);
      return convertListReference(pigeonReferenceList);
    } catch (e, stack) {
      convertPlatformException(e, stack);
    }
  }

  @override
  Future<ListResultPlatform> listAll() async {
    try {
      PigeonListResult pigeonReferenceList = await MethodChannelFirebaseStorage
          .pigeonChannel
          .referenceListAll(pigeonFirebaseApp, pigeonReference);
      return convertListReference(pigeonReferenceList);
    } catch (e, stack) {
      convertPlatformException(e, stack);
    }
  }

  @override
  Future<Uint8List?> getData(int maxSize, [CancelToken? cancelToken]) async {
    try {
      if (cancelToken != null) {
        if (cancelToken.isCancelled) {
          throw FirebaseException(
            plugin: 'firebase_storage',
            code: 'canceled',
            message: 'The operation was canceled.',
          );
        }

        final Completer<Uint8List?> completer = Completer<Uint8List?>();
        final List<int> data = [];
        late StreamSubscription<Uint8List> subscription;

        subscription = streamData(maxSize).listen(
          data.addAll,
          onError: (e) {
            if (!completer.isCompleted) {
              completer.completeError(e);
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.complete(Uint8List.fromList(data));
            }
          },
          cancelOnError: true,
        );

        cancelToken.onCancelled.then((_) async {
          if (!completer.isCompleted) {
            await subscription.cancel();
            completer.completeError(FirebaseException(
              plugin: 'firebase_storage',
              code: 'canceled',
              message: 'The operation was canceled.',
            ));
          }
        });

        return await completer.future;
      }
      return await MethodChannelFirebaseStorage.pigeonChannel
          .referenceGetData(pigeonFirebaseApp, pigeonReference, maxSize);
    } catch (e, stack) {
      convertPlatformException(e, stack);
    }
  }

  @override
  Stream<Uint8List> streamData(int maxSize) async* {
    try {
      final handle = MethodChannelFirebaseStorage.nextMethodChannelHandleId;
      final channelName = await MethodChannelFirebaseStorage.pigeonChannel
          .referenceStreamData(
              pigeonFirebaseApp, pigeonReference, maxSize, handle);

      final eventChannel = EventChannel(channelName);
      final stream = eventChannel.receiveBroadcastStream();

      int totalBytesReceived = 0;
      await for (final event in stream) {
        if (event is Map) {
          final eventMap = Map<String, dynamic>.from(event);

          // Check for error events
          if (eventMap.containsKey('error')) {
            final errorMap = Map<String, dynamic>.from(eventMap['error']);
            throw FirebaseException(
              plugin: 'firebase_storage',
              code: errorMap['code'] ?? 'unknown',
              message: errorMap['message'] ?? 'An error occurred',
            );
          }

          // Check for data chunks
          if (eventMap.containsKey('data')) {
            final data = eventMap['data'];
            if (data is Uint8List) {
              totalBytesReceived += data.length;
              if (maxSize > 0 && totalBytesReceived > maxSize) {
                throw FirebaseException(
                  plugin: 'firebase_storage',
                  code: 'download-size-exceeded',
                  message:
                      'Downloaded data exceeds maximum allowed size of $maxSize bytes',
                );
              }
              yield data;
            }
          }

          // Check for completion
          if (eventMap.containsKey('complete') &&
              eventMap['complete'] == true) {
            break;
          }
        } else if (event is Uint8List) {
          // Direct data chunk
          totalBytesReceived += event.length;
          if (maxSize > 0 && totalBytesReceived > maxSize) {
            throw FirebaseException(
              plugin: 'firebase_storage',
              code: 'download-size-exceeded',
              message:
                  'Downloaded data exceeds maximum allowed size of $maxSize bytes',
            );
          }
          yield event;
        }
      }
    } catch (e, stack) {
      convertPlatformException(e, stack);
    }
  }

  @override
  TaskPlatform putData(Uint8List data, [SettableMetadata? metadata]) {
    int handle = MethodChannelFirebaseStorage.nextMethodChannelHandleId;
    return MethodChannelPutTask(handle, storage, fullPath, data, metadata);
  }

  @override
  TaskPlatform putBlob(dynamic data, [SettableMetadata? metadata]) {
    throw UnimplementedError(
        'putBlob() is not supported on native platforms. Use [put], [putFile] or [putString] instead.');
  }

  @override
  TaskPlatform putFile(File file, [SettableMetadata? metadata]) {
    int handle = MethodChannelFirebaseStorage.nextMethodChannelHandleId;
    return MethodChannelPutFileTask(handle, storage, fullPath, file, metadata);
  }

  @override
  TaskPlatform putString(String data, PutStringFormat format,
      [SettableMetadata? metadata]) {
    int handle = MethodChannelFirebaseStorage.nextMethodChannelHandleId;
    return MethodChannelPutStringTask(
        handle, storage, fullPath, data, format, metadata);
  }

  /// Convert a [SettableMetadata] to [PigeonSettableMetadata]
  PigeonSettableMetadata convertToPigeonMetaData(SettableMetadata data) {
    return PigeonSettableMetadata(
      cacheControl: data.cacheControl,
      contentDisposition: data.contentDisposition,
      contentEncoding: data.contentEncoding,
      contentLanguage: data.contentLanguage,
      contentType: data.contentType,
      customMetadata: data.customMetadata,
    );
  }

  @override
  Future<FullMetadata> updateMetadata(SettableMetadata metadata) async {
    try {
      PigeonFullMetaData updatedMetaData = await MethodChannelFirebaseStorage
          .pigeonChannel
          .referenceUpdateMetadata(pigeonFirebaseApp, pigeonReference,
              convertToPigeonMetaData(metadata));
      return convertMetadata(updatedMetaData);
    } catch (e, stack) {
      convertPlatformException(e, stack);
    }
  }

  @override
  TaskPlatform writeToFile(File file) {
    int handle = MethodChannelFirebaseStorage.nextMethodChannelHandleId;
    return MethodChannelDownloadTask(handle, storage, fullPath, file);
  }
}
