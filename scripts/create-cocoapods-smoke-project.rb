#!/usr/bin/env ruby

require "fileutils"
require "xcodeproj"

output_dir = File.expand_path(ARGV.fetch(0))
smoke_endpoint = ARGV.fetch(1)
source_dir = File.join(output_dir, "Tests")
FileUtils.mkdir_p(source_dir)

test_source = <<~SWIFT
  import DebugBundle
  import Foundation
  import XCTest

  final class DebugBundleCocoaPodsSmokeTests: XCTestCase {
      func testCleanPodDeliversAndAcknowledgesEvents() async throws {
          let endpoint = URL(string: "#{smoke_endpoint}")!

          let traceID = "11111111111111111111111111111111"
          let queueURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("debugbundle-swift-pod-smoke-\\(UUID().uuidString).json")
          defer { try? FileManager.default.removeItem(at: queueURL) }

          let client = DebugBundleClient(
              config: DebugBundleConfig(
                  projectToken: "dbundle_proj_swift_smoke",
                  environment: "smoke",
                  service: "swift-cocoapods-smoke",
                  endpoint: endpoint,
                  batchSize: 25,
                  flushInterval: 60,
                  requestTimeout: 5,
                  offlineQueueURL: queueURL
              ),
              transport: DebugBundleHTTPTransport(),
              connectivityMonitor: SmokeConnectivityMonitor()
          )

          client.captureException(
              CocoaPodsSmokeFailure("clean CocoaPods consumer exception"),
              context: ["trace_id": traceID]
          )
          client.captureRequest(
              DebugBundleRequestInfo(
                  method: "GET",
                  url: "https://example.test/smoke?mode=cocoapods",
                  traceId: traceID
              ),
              response: DebugBundleResponseInfo(statusCode: 503, durationMillis: 25)
          )
          await client.flush()

          XCTAssertEqual(client.status, .healthy)
          XCTAssertNotNil(client.lastEventAt)
      }
  }

  // Keep the two-event HTTP fixture independent of simulator path-change callbacks.
  private final class SmokeConnectivityMonitor: DebugBundleConnectivityMonitoring {
      var currentStatus: DebugBundleConnectivityStatus { .connected }
      func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?) {}
  }

  private struct CocoaPodsSmokeFailure: Error {
      let description: String
      init(_ description: String) { self.description = description }
  }
SWIFT

source_path = File.join(source_dir, "DebugBundleCocoaPodsSmokeTests.swift")
File.write(source_path, test_source)

project_path = File.join(output_dir, "DebugBundlePodSmoke.xcodeproj")
project = Xcodeproj::Project.new(project_path)
target = project.new_target(:unit_test_bundle, "DebugBundlePodSmokeTests", :ios, "15.0")
target.build_configurations.each do |configuration|
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.debugbundle.pod-smoke-tests"
  configuration.build_settings["SWIFT_VERSION"] = "5.10"
end

group = project.main_group.new_group("Tests", "Tests")
source_reference = group.new_file("DebugBundleCocoaPodsSmokeTests.swift")
target.add_file_references([source_reference])
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(target)
scheme.save_as(project.path, "DebugBundlePodSmoke", true)
