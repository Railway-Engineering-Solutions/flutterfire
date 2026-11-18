// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import FirebaseFirestore
import Foundation

#if canImport(firebase_core)
  import firebase_core
#else
  import firebase_core_shared
#endif

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

private let kStandardFieldList: UInt8 = 12
private let kStandardFieldMap: UInt8 = 13

/// Encodes Firestore values for the platform channel.
///
/// Snapshot events are encoded on the main thread, which on iOS is also the
/// thread Dart runs on, so the cost of every document field lands directly on
/// the app's frame budget. A query snapshot carries every document of the
/// result twice (the documents and, on a first or rebuilt snapshot, the
/// changes), so a large collection means hundreds of thousands of values per
/// event.
///
/// Document data arrives as Foundation objects. They are classified with one
/// class check each and written here, recursing through [writeElement] rather
/// than [writeValue], so a nested value never re-enters the Pigeon codec's
/// override: that override tries two dozen Swift dynamic casts on every value
/// it sees, and the Swift collection casts in [writeOtherValue] copy a whole
/// container to inspect it. Only values this writer does not recognise (the
/// Pigeon structs and enums wrapping a snapshot, Swift scalars, and the rarer
/// Firestore types) take the dynamic path.
class FirebaseFirestoreWriter: FlutterStandardWriter {
  override func writeValue(_ value: Any) {
    if writeKnownValue(value) {
      return
    }
    writeOtherValue(value)
  }

  /// Writes one element of a list or map.
  ///
  /// Recognised values are written directly; anything else goes through
  /// [writeValue], so a subclass (the Pigeon codec) still encodes its own
  /// types.
  final func writeElement(_ value: Any) {
    if writeKnownValue(value) {
      return
    }
    writeValue(value)
  }

  /// Writes [value] if it is one of the common shapes of snapshot data,
  /// returning whether it did. Never calls [writeValue] for [value] itself.
  private final func writeKnownValue(_ value: Any) -> Bool {
    // Only a class instance can be a Foundation object. Checking the dynamic
    // type first means a Swift value is never bridged just to classify it.
    if Swift.type(of: value) is AnyClass {
      return writeKnownObject(value as AnyObject)
    }
    // Map keys of the top-level document data are Swift strings.
    if let string = value as? String {
      super.writeValue(string)
      return true
    }
    // The Swift containers Pigeon builds a snapshot from. Their elements are
    // optional, so unwrap each one here instead of handing an `Optional` to
    // the dynamic casts.
    if let map = value as? [String?: Any?] {
      writeByte(kStandardFieldMap)
      writeSize(UInt32(map.count))
      for (key, item) in map {
        writeOptional(key)
        writeOptional(item)
      }
      return true
    }
    if let list = value as? [Any?] {
      writeByte(kStandardFieldList)
      writeSize(UInt32(list.count))
      for item in list {
        writeOptional(item)
      }
      return true
    }
    return false
  }

  private final func writeOptional(_ value: Any?) {
    if let value {
      writeElement(value)
    } else {
      super.writeValue(NSNull())
    }
  }

  /// The Foundation and Firestore classes document data is made of, most
  /// frequent first. Each check is an Objective-C class test.
  private final func writeKnownObject(_ object: AnyObject) -> Bool {
    if let string = object as? NSString {
      super.writeValue(string)
    } else if let number = object as? NSNumber {
      writeNumber(number)
    } else if let map = object as? NSDictionary {
      writeByte(kStandardFieldMap)
      writeSize(UInt32(map.count))
      map.enumerateKeysAndObjects { key, item, _ in
        self.writeElement(key)
        self.writeElement(item)
      }
    } else if let list = object as? NSArray {
      writeByte(kStandardFieldList)
      writeSize(UInt32(list.count))
      for item in list {
        writeElement(item)
      }
    } else if object is NSNull {
      super.writeValue(object)
    } else if let timestamp = object as? Timestamp {
      writeTimestamp(timestamp)
    } else if let geoPoint = object as? GeoPoint {
      writeGeoPoint(geoPoint)
    } else if let document = object as? DocumentReference {
      writeDocumentReference(document)
    } else if let blob = object as? NSData {
      writeBlob(blob as Data)
    } else {
      return false
    }
    return true
  }

  /// Everything [writeKnownValue] does not handle: dates, vectors, SDK
  /// snapshot objects, other Swift collections and scalars.
  private final func writeOtherValue(_ value: Any) {
    if let date = value as? Date {
      writeByte(FirestoreDataType.dateTime.rawValue)
      var ms = Int64(date.timeIntervalSince1970 * 1000.0)
      writeBytes(&ms, length: 8)
    } else if let timestamp = value as? Timestamp {
      writeTimestamp(timestamp)
    } else if let geoPoint = value as? GeoPoint {
      writeGeoPoint(geoPoint)
    } else if let vector = value as? VectorValue {
      writeByte(FirestoreDataType.vectorValue.rawValue)
      writeValue(vector.array)
    } else if let document = value as? DocumentReference {
      writeDocumentReference(document)
    } else if let snapshot = value as? DocumentSnapshot {
      writeValue(documentSnapshotMap(snapshot))
    } else if let progress = value as? LoadBundleTaskProgress {
      writeValue(loadBundleTaskProgressMap(progress))
    } else if let snapshot = value as? QuerySnapshot {
      writeValue(querySnapshotMap(snapshot))
    } else if let change = value as? DocumentChange {
      writeValue(documentChangeMap(change))
    } else if let metadata = value as? SnapshotMetadata {
      writeValue(snapshotMetadataMap(metadata))
    } else if let list = value as? [Any] {
      writeByte(kStandardFieldList)
      writeSize(UInt32(list.count))
      for item in list {
        writeElement(item)
      }
    } else if let map = value as? [AnyHashable: Any] {
      writeByte(kStandardFieldMap)
      writeSize(UInt32(map.count))
      for (key, item) in map {
        writeElement(key.base)
        writeElement(item)
      }
    } else if let number = value as? NSNumber {
      writeNumber(number)
    } else if let blob = value as? Data {
      writeBlob(blob)
    } else {
      super.writeValue(value)
    }
  }

  private final func writeNumber(_ number: NSNumber) {
    // Only a floating-point number can be NaN or infinite. Reading the type
    // code avoids formatting every number to look for "nan".
    let type = number.objCType.pointee
    if type == 0x64 /* d */ || type == 0x66 /* f */ {
      let double = number.doubleValue
      if double.isNaN {
        writeByte(FirestoreDataType.nan.rawValue)
        return
      }
      if double == .infinity {
        writeByte(FirestoreDataType.infinity.rawValue)
        return
      }
      if double == -.infinity {
        writeByte(FirestoreDataType.negativeInfinity.rawValue)
        return
      }
    }
    super.writeValue(number)
  }

  private final func writeTimestamp(_ timestamp: Timestamp) {
    var seconds = timestamp.seconds
    var nanoseconds = timestamp.nanoseconds
    writeByte(FirestoreDataType.timestamp.rawValue)
    writeBytes(&seconds, length: 8)
    writeBytes(&nanoseconds, length: 4)
  }

  private final func writeGeoPoint(_ geoPoint: GeoPoint) {
    var latitude = geoPoint.latitude
    var longitude = geoPoint.longitude
    writeByte(FirestoreDataType.geoPoint.rawValue)
    writeAlignment(8)
    writeBytes(&latitude, length: 8)
    writeBytes(&longitude, length: 8)
  }

  private final func writeDocumentReference(_ document: DocumentReference) {
    writeByte(FirestoreDataType.documentReference.rawValue)
    writeElement(FLTFirebasePlugin.firebaseAppName(fromIosName: document.firestore.app.name))
    writeElement(document.path)
    let extensionInstance = FirebaseFirestoreUtils.cachedInstance(for: document.firestore)
    writeElement(extensionInstance.databaseURL)
  }

  private final func writeBlob(_ blob: Data) {
    writeByte(FirestoreDataType.blob.rawValue)
    writeSize(UInt32(blob.count))
    write(blob)
  }

  private func snapshotMetadataMap(_ snapshotMetadata: SnapshotMetadata) -> [String: Any] {
    [
      "hasPendingWrites": snapshotMetadata.hasPendingWrites,
      "isFromCache": snapshotMetadata.isFromCache,
    ]
  }

  private func documentChangeMap(_ documentChange: DocumentChange) -> [String: Any] {
    let type: String
    switch documentChange.type {
    case .added:
      type = "DocumentChangeType.added"
    case .modified:
      type = "DocumentChangeType.modified"
    case .removed:
      type = "DocumentChangeType.removed"
    @unknown default:
      type = "DocumentChangeType.modified"
    }

    let maxVal = NSNotFound
    let newIndex: Int
    if documentChange.newIndex == NSNotFound || documentChange.newIndex == 4_294_967_295
      || documentChange.newIndex == maxVal
    {
      newIndex = -1
    } else {
      newIndex = Int(documentChange.newIndex)
    }

    let oldIndex: Int
    if documentChange.oldIndex == NSNotFound || documentChange.oldIndex == 4_294_967_295
      || documentChange.oldIndex == maxVal
    {
      oldIndex = -1
    } else {
      oldIndex = Int(documentChange.oldIndex)
    }

    return [
      "type": type,
      "data": documentChange.document.data(),
      "path": documentChange.document.reference.path,
      "oldIndex": oldIndex,
      "newIndex": newIndex,
      "metadata": documentChange.document.metadata,
    ]
  }

  private func serverTimestampBehavior(from string: String?)
    -> FirebaseFirestore
    .ServerTimestampBehavior
  {
    switch string {
    case "estimate":
      return .estimate
    case "previous":
      return .previous
    default:
      return .none
    }
  }

  private func documentSnapshotMap(_ documentSnapshot: DocumentSnapshot) -> [String: Any]? {
    let hash = NSNumber(value: documentSnapshot.hash)
    let timestampBehaviorString =
      FLTFirebaseFirestorePlugin.serverTimestampMap.object(forKey: hash) as String?
    let behavior = serverTimestampBehavior(from: timestampBehaviorString)
    FLTFirebaseFirestorePlugin.serverTimestampMap.removeObject(forKey: hash)

    let data: Any =
      documentSnapshot.exists
      ? documentSnapshot.data(with: behavior) as Any : NSNull()
    return [
      "path": documentSnapshot.reference.path,
      "data": data,
      "metadata": documentSnapshot.metadata,
    ]
  }

  private func loadBundleTaskProgressMap(_ progress: LoadBundleTaskProgress) -> [String: Any] {
    let state: String
    switch progress.state {
    case .error:
      state = "error"
    case .success:
      state = "success"
    case .inProgress:
      state = "running"
    @unknown default:
      state = "running"
    }
    return [
      "bytesLoaded": progress.bytesLoaded,
      "documentsLoaded": progress.documentsLoaded,
      "totalBytes": progress.totalBytes,
      "totalDocuments": progress.totalDocuments,
      "taskState": state,
    ]
  }

  private func querySnapshotMap(_ querySnapshot: QuerySnapshot) -> [String: Any]? {
    let hash = NSNumber(value: querySnapshot.hash)
    let timestampBehaviorString =
      FLTFirebaseFirestorePlugin.serverTimestampMap.object(forKey: hash) as String?
    let behavior = serverTimestampBehavior(from: timestampBehaviorString)
    FLTFirebaseFirestorePlugin.serverTimestampMap.removeObject(forKey: hash)

    var paths: [String] = []
    var documents: [[String: Any]] = []
    var metadatas: [SnapshotMetadata] = []
    for document in querySnapshot.documents {
      paths.append(document.reference.path)
      documents.append(document.data(with: behavior) ?? [:])
      metadatas.append(document.metadata)
    }

    return [
      "paths": paths,
      "documentChanges": querySnapshot.documentChanges,
      "documents": documents,
      "metadatas": metadatas,
      "metadata": querySnapshot.metadata,
    ]
  }
}
