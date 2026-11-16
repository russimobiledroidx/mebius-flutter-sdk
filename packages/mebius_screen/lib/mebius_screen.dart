/// Desktop screen share for Mebius: an agent that enrolls a device, publishes
/// its screen on demand and applies remote input, and a viewer that watches
/// and controls it.
library;

export 'package:mebius/mebius.dart' show MebiusError, MebiusErrorCode;

export 'src/agent.dart' show MebiusScreenAgent, MebiusScreenSession;
export 'src/credentials.dart'
    show
        MebiusCredentialStore,
        MebiusDeviceCredentials,
        MebiusSecureCredentialStore;
export 'src/input_event.dart' show MebiusInputEvent;
export 'src/view.dart' show MebiusScreenView;
export 'src/viewer.dart' show MebiusScreenViewer;
