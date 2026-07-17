package app.droidmatch.m1;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.Collections;

import org.junit.Test;

public final class SafGrantStatePolicyTest {
    @Test
    public void confirmationRequiresAnAuthoritativeWellFormedSnapshot() {
        DmFileProvider.SafRoot target = new DmFileProvider.SafRoot(
                "target", "primary:Target", "Target", true
        );
        DmFileProvider.SafRoot other = new DmFileProvider.SafRoot(
                "other", "primary:Other", "Other", false
        );

        assertTrue(SafGrantStatePolicy.grantConfirmed("target", Arrays.asList(other, target)));
        assertFalse(SafGrantStatePolicy.grantConfirmed("target", Collections.singletonList(other)));
        assertFalse(SafGrantStatePolicy.grantConfirmed("target", null));
        assertFalse(SafGrantStatePolicy.grantConfirmed("target", Arrays.asList(other, null)));

        assertTrue(SafGrantStatePolicy.removalConfirmed("target", Collections.singletonList(other)));
        assertTrue(SafGrantStatePolicy.removalConfirmed("target", Collections.emptyList()));
        assertFalse(SafGrantStatePolicy.removalConfirmed("target", Arrays.asList(other, target)));
        assertFalse(SafGrantStatePolicy.removalConfirmed("target", null));
        assertFalse(SafGrantStatePolicy.removalConfirmed("target", Arrays.asList(other, null)));
    }
}
