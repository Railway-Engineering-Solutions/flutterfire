// Copyright 2026, the Chromium project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import FirebaseFirestore
import Foundation
import XCTest

@testable import cloud_firestore

/// Snapshot events are encoded on the main thread, which on iOS is the thread
/// Dart runs on. These tests pin the wire format of the writer for Foundation
/// document data, and time a large snapshot.
final class SnapshotEncodingTests: XCTestCase {
  private let codec = FirestoreMessagesPigeonCodec.shared

  /// Document data as `DocumentSnapshot.data()` returns it: Foundation
  /// objects all the way down.
  private func documentData(_ index: Int) -> [String: Any] {
    [
      "title": "Asset \(index)" as NSString,
      "count": NSNumber(value: index),
      "ratio": NSNumber(value: Double(index) / 7.0),
      "active": NSNumber(value: index % 2 == 0),
      "missing": NSNull(),
      "updatedAt": Timestamp(seconds: 1_700_000_000 + Int64(index), nanoseconds: 1234),
      "location": GeoPoint(latitude: -37.8, longitude: 144.9),
      "tags": NSArray(array: ["a" as NSString, NSNumber(value: 1), NSNull()]),
      "customFields": NSDictionary(dictionary: [
        "Chainage": "12.5" as NSString,
        "Nested": NSDictionary(dictionary: [
          "list": NSArray(array: [NSNumber(value: 2.5), "x" as NSString])
        ]),
      ]),
    ]
  }

  private func snapshot(documentCount: Int) -> InternalQuerySnapshot {
    let metadata = InternalSnapshotMetadata(hasPendingWrites: false, isFromCache: true)
    var documents: [InternalDocumentSnapshot?] = []
    var changes: [InternalDocumentChange?] = []
    for index in 0..<documentCount {
      let document = InternalDocumentSnapshot(
        path: "items/\(index)",
        data: PigeonParser.toPigeonMap(documentData(index)),
        metadata: metadata
      )
      documents.append(document)
      changes.append(
        InternalDocumentChange(
          type: .added, document: document, oldIndex: -1, newIndex: Int64(index)))
    }
    return InternalQuerySnapshot(
      documents: documents, documentChanges: changes, metadata: metadata)
  }

  func testQuerySnapshotRoundTripsDocumentData() throws {
    let encoded = try XCTUnwrap(codec.encode(snapshot(documentCount: 3)))
    let decoded = try XCTUnwrap(codec.decode(encoded) as? InternalQuerySnapshot)

    XCTAssertEqual(decoded.documents.count, 3)
    XCTAssertEqual(decoded.documentChanges.count, 3)
    XCTAssertEqual(decoded.metadata.isFromCache, true)
    for index in 0..<3 {
      let document = try XCTUnwrap(decoded.documents[index])
      XCTAssertEqual(document.path, "items/\(index)")
      var plain: [String: Any] = [:]
      for (key, value) in try XCTUnwrap(document.data) {
        let name = try XCTUnwrap(key)
        plain[name] = value ?? NSNull()
      }
      XCTAssertEqual(
        NSDictionary(dictionary: plain), NSDictionary(dictionary: documentData(index)))

      let change = try XCTUnwrap(decoded.documentChanges[index])
      XCTAssertEqual(change.type, .added)
      XCTAssertEqual(change.newIndex, Int64(index))
      XCTAssertEqual(change.document.path, "items/\(index)")
    }
  }

  func testNonFiniteNumbersUseFirestoreTypeCodes() throws {
    XCTAssertEqual(
      try XCTUnwrap(codec.encode(NSNumber(value: Double.nan))),
      Data([FirestoreDataType.nan.rawValue]))
    XCTAssertEqual(
      try XCTUnwrap(codec.encode(NSNumber(value: Double.infinity))),
      Data([FirestoreDataType.infinity.rawValue]))
    XCTAssertEqual(
      try XCTUnwrap(codec.encode(NSNumber(value: -Double.infinity))),
      Data([FirestoreDataType.negativeInfinity.rawValue]))
    XCTAssertEqual(
      try XCTUnwrap(codec.encode(NSNumber(value: Float.nan))),
      Data([FirestoreDataType.nan.rawValue]))
  }

  func testFiniteNumbersStayStandard() throws {
    let values: [NSNumber] = [
      NSNumber(value: 0), NSNumber(value: 42), NSNumber(value: Int64.max),
      NSNumber(value: 1.5), NSNumber(value: true),
    ]
    for value in values {
      let decoded = codec.decode(try XCTUnwrap(codec.encode(value))) as? NSNumber
      XCTAssertEqual(decoded, value)
    }
  }

  /// A large first snapshot: each document is encoded twice, once as a
  /// document and once as its "added" change.
  func testLargeSnapshotEncodingTime() {
    let large = snapshot(documentCount: 5000)
    measure {
      _ = codec.encode(large)
    }
  }
}
