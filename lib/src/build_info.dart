/// Set by the desktop distribution build wrapper from pubspec.yaml. Direct
/// developer runs identify themselves honestly instead of showing a stale tag.
const applicationVersion = String.fromEnvironment(
  'PROTODESK_VERSION',
  defaultValue: 'Development build',
);
