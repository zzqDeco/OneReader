# Native Share Extension

UIKit hosts a native SwiftUI receipt screen. Each NSItemProvider is handled
independently with bounded timeout/cancellation and per-attachment feedback.
File representations are copied within the callback lifetime.

The extension only depends on CaptureModels and CaptureStagingStore. It does
not open the app, fetch URLs, index, access Library SQLite, read Keychain or
invoke models. A matching App Group entitlement is mandatory for success.
