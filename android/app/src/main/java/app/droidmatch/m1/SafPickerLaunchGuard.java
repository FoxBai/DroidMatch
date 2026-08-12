package app.droidmatch.m1;

import android.content.ActivityNotFoundException;

/** Keeps known system-picker availability failures inside the product UI boundary. */
final class SafPickerLaunchGuard {
    interface LaunchAction {
        void launch();
    }

    private SafPickerLaunchGuard() {}

    static boolean launch(LaunchAction action) {
        try {
            action.launch();
            return true;
        } catch (ActivityNotFoundException | SecurityException exception) {
            return false;
        }
    }
}
