package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.graphics.Rect;
import android.os.Build;
import android.util.DisplayMetrics;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.Assume;
import org.junit.runner.RunWith;

/** Device-level regression for the compact API 26 launcher viewport. */
@RunWith(AndroidJUnit4.class)
public final class DroidMatchActivityLayoutInstrumentationTest {
    private static final String LAYOUT_PROFILE = "slot-a-704sh-layout-v2";

    @Test
    @SuppressWarnings("deprecation") // The profile is intentionally fixed to API 26 Display APIs.
    public void compactLauncherFitsActionsAndScrollsToTheLastControl() {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        Assume.assumeTrue(
                "the 704SH layout profile was not explicitly requested",
                LAYOUT_PROFILE.equals(
                        InstrumentationRegistry.getArguments().getString("layout_profile")
                )
        );
        assertEquals(26, Build.VERSION.SDK_INT);
        assertEquals("704SH", Build.MODEL);
        assertEquals(320, instrumentation.getTargetContext()
                .getResources()
                .getDisplayMetrics()
                .densityDpi);
        assertEquals(
                1.3f,
                instrumentation.getTargetContext()
                        .getResources()
                        .getConfiguration()
                        .fontScale,
                0.001f
        );
        Intent launchIntent = instrumentation.getTargetContext()
                .getPackageManager()
                .getLaunchIntentForPackage("app.droidmatch");
        assertNotNull(launchIntent);
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);

        Activity activity = instrumentation.startActivitySync(launchIntent);
        instrumentation.waitForIdleSync();
        try {
            assertNull(activity.getActionBar());
            DisplayMetrics realMetrics = new DisplayMetrics();
            activity.getWindowManager().getDefaultDisplay().getRealMetrics(realMetrics);
            assertEquals(720, realMetrics.widthPixels);
            assertEquals(1_280, realMetrics.heightPixels);
            assertEquals(320, realMetrics.densityDpi);
            assertEquals(
                    "en",
                    activity.getResources().getConfiguration().getLocales().get(0).getLanguage()
            );
            assertEquals(
                    "US",
                    activity.getResources().getConfiguration().getLocales().get(0).getCountry()
            );
            View content = activity.findViewById(android.R.id.content);
            ScrollView scrollView = findFirst(content, ScrollView.class);
            assertNotNull(scrollView);
            assertEquals(720, scrollView.getWidth());
            assertEquals(1_136, scrollView.getHeight());
            Button firstAction = activity.findViewById(R.id.connection_enable_button);
            assertNotNull(firstAction);
            assertEquals(1, countViewsWithId(scrollView, R.id.connection_enable_button));
            assertEquals(
                    activity.getString(R.string.connection_enable),
                    firstAction.getText().toString()
            );
            assertEquals("Enable secure USB", firstAction.getText().toString());
            assertTrue("the 704SH English label must exercise two lines", firstAction.getLineCount() >= 2);
            assertEquals(0, scrollView.getScrollY());

            assertFullyInsideViewport(
                    scrollView,
                    firstAction,
                    "the first secure-USB action must fit in the initial viewport"
            );
            assertActionRowUsesUniformHeight(
                    activity.findViewById(R.id.connection_actions),
                    "secure-USB actions"
            );
            assertActionRowUsesUniformHeight(
                    activity.findViewById(R.id.pairing_decisions),
                    "pairing decisions"
            );
            assertVisibleButtonTextFits(scrollView);

            Button lastAction = activity.findViewById(R.id.storage_add_folder_button);
            assertNotNull(lastAction);
            assertTrue("the compact launcher must be scrollable", scrollView.canScrollVertically(1));
            activity.runOnUiThread(() -> scrollView.scrollTo(
                    0,
                    scrollView.getChildAt(0).getHeight()
            ));
            instrumentation.waitForIdleSync();
            assertFalse(
                    "the compact launcher must reach its final control",
                    scrollView.canScrollVertically(1)
            );
            assertFullyInsideViewport(
                    scrollView,
                    lastAction,
                    "the add-folder action must fit above the system navigation area"
            );
        } finally {
            activity.finish();
        }
    }

    private static void assertActionRowUsesUniformHeight(LinearLayout row, String description) {
        assertNotNull(row);
        assertEquals(LinearLayout.HORIZONTAL, row.getOrientation());
        assertEquals(2, row.getChildCount());
        assertTrue(row.getChildAt(0) instanceof Button);
        assertTrue(row.getChildAt(1) instanceof Button);
        assertEquals(description + " must share the taller label's height",
                row.getChildAt(0).getHeight(), row.getChildAt(1).getHeight());
    }

    private static void assertFullyInsideViewport(
            ScrollView scrollView,
            View descendant,
            String message
    ) {
        int[] viewportLocation = new int[2];
        int[] descendantLocation = new int[2];
        scrollView.getLocationOnScreen(viewportLocation);
        descendant.getLocationOnScreen(descendantLocation);
        Rect viewport = new Rect(
                viewportLocation[0],
                viewportLocation[1],
                viewportLocation[0] + scrollView.getWidth(),
                viewportLocation[1] + scrollView.getHeight()
        );
        Rect bounds = new Rect(
                descendantLocation[0],
                descendantLocation[1],
                descendantLocation[0] + descendant.getWidth(),
                descendantLocation[1] + descendant.getHeight()
        );
        assertTrue(message, viewport.contains(bounds));
    }

    private static <ViewType extends View> ViewType findFirst(
            View root,
            Class<ViewType> viewType
    ) {
        if (viewType.isInstance(root)) {
            return viewType.cast(root);
        }
        if (!(root instanceof ViewGroup)) {
            return null;
        }
        ViewGroup group = (ViewGroup) root;
        for (int index = 0; index < group.getChildCount(); index += 1) {
            ViewType match = findFirst(group.getChildAt(index), viewType);
            if (match != null) {
                return match;
            }
        }
        return null;
    }

    private static int countViewsWithId(View root, int viewId) {
        int count = root.getId() == viewId ? 1 : 0;
        if (!(root instanceof ViewGroup)) {
            return count;
        }
        ViewGroup group = (ViewGroup) root;
        for (int index = 0; index < group.getChildCount(); index += 1) {
            count += countViewsWithId(group.getChildAt(index), viewId);
        }
        return count;
    }

    private static void assertVisibleButtonTextFits(View root) {
        if (root instanceof Button && root.getVisibility() == View.VISIBLE) {
            Button button = (Button) root;
            assertNotNull(button.getLayout());
            int requiredTextHeight = button.getLayout().getHeight()
                    + button.getCompoundPaddingTop()
                    + button.getCompoundPaddingBottom();
            assertTrue(
                    "scaled or localized button text must not be clipped",
                    requiredTextHeight <= button.getHeight()
            );
        }
        if (!(root instanceof ViewGroup)) {
            return;
        }
        ViewGroup group = (ViewGroup) root;
        for (int index = 0; index < group.getChildCount(); index += 1) {
            assertVisibleButtonTextFits(group.getChildAt(index));
        }
    }
}
