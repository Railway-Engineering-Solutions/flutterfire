/*
 * Copyright 2025, the Chromium project authors.
 * Use of this source code is governed by a BSD-style license that can be found in the LICENSE file.
 */
package io.flutter.plugins.firebase.storage

import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.EventChannel.StreamHandler
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

internal class DataStreamChannelStreamHandler(
  private val downloadUrl: String,
  private val maxSize: Long
) : StreamHandler {
  private val isCancelled = AtomicBoolean(false)
  private var scope: CoroutineScope? = null

  override fun onListen(arguments: Any?, events: EventSink) {
    isCancelled.set(false)
    scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    
    scope?.launch {
      try {
        val url = URL(downloadUrl)
        val connection = url.openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connect()
        
        if (connection.responseCode != HttpURLConnection.HTTP_OK) {
          val errorMap = mapOf(
            "code" to "unknown",
            "message" to "Failed to download file: HTTP ${connection.responseCode}"
          )
          events.success(mapOf("error" to errorMap))
          return@launch
        }
        
        val inputStream: InputStream = connection.inputStream
        val buffer = ByteArray(8192) // 8KB chunks
        var totalBytesRead = 0L
        
        try {
          while (!isCancelled.get()) {
            val bytesRead = inputStream.read(buffer)
            if (bytesRead == -1) {
              // End of stream
              events.success(mapOf("complete" to true))
              break
            }
            
            totalBytesRead += bytesRead
            if (maxSize > 0 && totalBytesRead > maxSize) {
              val errorMap = mapOf(
                "code" to "download-size-exceeded",
                "message" to "Downloaded data exceeds maximum allowed size of $maxSize bytes"
              )
              events.success(mapOf("error" to errorMap))
              break
            }
            
            val chunk = buffer.copyOf(bytesRead)
            events.success(mapOf("data" to chunk))
          }
        } finally {
          inputStream.close()
          connection.disconnect()
        }
      } catch (e: Exception) {
        if (!isCancelled.get()) {
          val errorMap = FlutterFirebaseStoragePlugin.getExceptionDetails(e)
          events.success(mapOf("error" to errorMap))
        }
      }
    }
  }

  override fun onCancel(arguments: Any?) {
    isCancelled.set(true)
    scope?.cancel()
    scope = null
  }
}

