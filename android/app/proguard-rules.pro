# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.google.firebase.** { *; }

# Keep all Bluetooth plugin classes
-keep class uz.greenwhite.spp_connection_plugin.** { *; }
-keep class com.example.flutter_bluetooth_classic.** { *; }

# Keep all plugin registrant
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }
