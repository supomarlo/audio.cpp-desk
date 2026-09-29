# Known Issues

This page lists confirmed issues in the current version that are not yet fixed.

## Resizing the window may crash (Windows)

- **Symptom**: When certain assistive tools are accessing this application's window, dragging a window edge to resize may crash the app. This is rare; it does not occur without such tools accessing the window.
- **Cause**: This is a known issue in the Flutter (Windows) engine. We have reported it to the Flutter team ([flutter/flutter#193410](https://github.com/flutter/flutter/issues/193410)) and provided a deterministic reproduction for the existing issue with the same root cause ([flutter/flutter#175041](https://github.com/flutter/flutter/issues/175041)). An upstream fix is in progress, and we will follow it to remove this issue.
- **Workaround**: Do not resize the window while assistive tools are accessing it (resize later, or pause the tool first). After a crash, restarting recovers the app, but it may recur while the trigger condition remains.
