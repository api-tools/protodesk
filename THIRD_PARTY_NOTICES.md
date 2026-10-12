# Third-party notices

ProtoDesk application code is licensed under MIT. Bundled dependencies retain their own licenses.

- Roboto Mono: Google/Christian Robertson, SIL Open Font License 1.1. Bundled from google/fonts, full terms in `assets/fonts/RobotoMono-OFL.txt`. Used consistently for JSON/code.
- Satoshi by Deni Anggara, Indian Type Foundry: ITF Free Font License. Downloaded from the official Fontshare API. Flutter-compatible TTF weights Light, Regular, Medium, and Bold are bundled as UI assets. Full terms: `assets/fonts/LICENSE.txt`. Do not redistribute the font files separately from the application.
- Protocol Buffers compiler and standard schemas: Google, BSD 3-Clause; full terms in `assets/protoc/LICENSE`. Official version 36.2 platform bundles from https://github.com/protocolbuffers/protobuf/releases/tag/v36.2. Used only to compile validated local proto schemas into descriptor sets.
- Dart HTTP/2: BSD-3-Clause, https://github.com/dart-lang/http. Version 3.1.0 supplies the cancellation handling fix; its transport API is verified with Dart gRPC in the automated suite.
- Dart gRPC: Apache-2.0, https://github.com/grpc/grpc-dart.
- SQLite: public domain, https://sqlite.org/copyright.html. Dart sqlite3 binding: MIT, https://github.com/simolus3/sqlite3.dart.
- Microsoft Visual C++ Runtime (Windows bundles): Microsoft redistributable components under the Visual Studio license, https://visualstudio.microsoft.com/license-terms/. These components keep their Microsoft license and are not covered by the application MIT license.
- Flutter and its framework: BSD-3-Clause; Material Icons: Apache-2.0. Flutter's generated license registry includes package notices in the compiled application.
- file_selector, path, uuid and their dependencies retain their package licenses. See the application's Flutter license registry for full license text.

`test/fixtures/test-only-key.pem` is a public, test-only TLS key. It is not used by the application and must never be used for a real server.
