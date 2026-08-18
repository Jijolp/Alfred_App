package com.example.alfred_app

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity() {
    companion object {
        init {
            System.loadLibrary("onnxruntime")
            System.loadLibrary("sherpa-onnx-c-api")
            System.loadLibrary("sherpa-onnx-jni")
        }
    }
}