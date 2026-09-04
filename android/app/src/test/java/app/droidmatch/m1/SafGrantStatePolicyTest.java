package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

import org.junit.Test;

public final class SafGrantStatePolicyTest {
    private static final String TARGET_URI = "content://provider/tree/primary%3Atarget";
    private static final String TARGET_ID = "target";

    @Test
    public void writeOnlyOrNonTreePickerResultNeverTakesPermission() {
        FakeGrantAccess writeOnly = new FakeGrantAccess(0);
        assertFalse(SafGrantStatePolicy.add(
                TARGET_URI,
                SafGrantStatePolicy.MODE_WRITE,
                TARGET_ID,
                writeOnly,
                SafGrantStatePolicyTest::targetRoots
        ));
        assertEquals(0, writeOnly.takeCalls);
        assertEquals(0, writeOnly.snapshotCalls);

        FakeGrantAccess nonTree = new FakeGrantAccess(0);
        nonTree.treeUri = false;
        assertFalse(SafGrantStatePolicy.add(
                TARGET_URI,
                SafGrantStatePolicy.MODE_READ,
                TARGET_ID,
                nonTree,
                SafGrantStatePolicyTest::targetRoots
        ));
        assertEquals(0, nonTree.takeCalls);
        assertEquals(0, nonTree.snapshotCalls);
    }

    @Test
    public void failedProductConfirmationRollsBackOnlyNewMode() {
        FakeGrantAccess access = new FakeGrantAccess(SafGrantStatePolicy.MODE_WRITE);

        assertFalse(SafGrantStatePolicy.add(
                TARGET_URI,
                SafGrantStatePolicy.MODE_READ | SafGrantStatePolicy.MODE_WRITE,
                TARGET_ID,
                access,
                Collections::emptyList
        ));

        assertEquals(1, access.takeCalls);
        assertEquals(1, access.releaseCalls);
        assertEquals(SafGrantStatePolicy.MODE_READ, access.lastReleasedModes);
        assertEquals(SafGrantStatePolicy.MODE_WRITE, access.modes);
    }

    @Test
    public void removalReleasesAllRawModesAndRejectsResidualMode() {
        FakeGrantAccess access = new FakeGrantAccess(
                SafGrantStatePolicy.MODE_READ | SafGrantStatePolicy.MODE_WRITE
        );
        access.leaveWriteOnRelease = true;

        assertFalse(SafGrantStatePolicy.remove(TARGET_URI, access));
        assertEquals(1, access.releaseCalls);
        assertEquals(
                SafGrantStatePolicy.MODE_READ | SafGrantStatePolicy.MODE_WRITE,
                access.lastReleasedModes
        );
        assertEquals(SafGrantStatePolicy.MODE_WRITE, access.modes);
    }

    @Test
    public void exactRawSnapshotsAdmitAddAndRemoveSuccess() {
        FakeGrantAccess access = new FakeGrantAccess(0);

        assertTrue(SafGrantStatePolicy.add(
                TARGET_URI,
                SafGrantStatePolicy.MODE_READ | SafGrantStatePolicy.MODE_WRITE,
                TARGET_ID,
                access,
                SafGrantStatePolicyTest::targetRoots
        ));
        assertEquals(
                SafGrantStatePolicy.MODE_READ | SafGrantStatePolicy.MODE_WRITE,
                access.modes
        );
        assertEquals(0, access.releaseCalls);

        assertTrue(SafGrantStatePolicy.remove(TARGET_URI, access));
        assertEquals(0, access.modes);
        assertEquals(
                SafGrantStatePolicy.MODE_READ | SafGrantStatePolicy.MODE_WRITE,
                access.lastReleasedModes
        );
    }

    @Test
    public void malformedOrUnavailableSnapshotsFailClosed() {
        FakeGrantAccess unavailable = new FakeGrantAccess(0);
        unavailable.failSnapshotAt = 1;
        assertFalse(SafGrantStatePolicy.add(
                TARGET_URI,
                SafGrantStatePolicy.MODE_READ,
                TARGET_ID,
                unavailable,
                SafGrantStatePolicyTest::targetRoots
        ));
        assertEquals(0, unavailable.takeCalls);

        FakeGrantAccess duplicate = new FakeGrantAccess(SafGrantStatePolicy.MODE_READ);
        duplicate.duplicateSnapshot = true;
        assertFalse(SafGrantStatePolicy.add(
                TARGET_URI,
                SafGrantStatePolicy.MODE_READ,
                TARGET_ID,
                duplicate,
                SafGrantStatePolicyTest::targetRoots
        ));
        assertEquals(0, duplicate.takeCalls);

        FakeGrantAccess postTakeUnavailable = new FakeGrantAccess(0);
        postTakeUnavailable.failSnapshotAt = 2;
        assertFalse(SafGrantStatePolicy.add(
                TARGET_URI,
                SafGrantStatePolicy.MODE_READ,
                TARGET_ID,
                postTakeUnavailable,
                SafGrantStatePolicyTest::targetRoots
        ));
        assertEquals(1, postTakeUnavailable.takeCalls);
        assertEquals(1, postTakeUnavailable.releaseCalls);
        assertEquals(SafGrantStatePolicy.MODE_READ, postTakeUnavailable.lastReleasedModes);
        assertEquals(0, postTakeUnavailable.modes);

        FakeGrantAccess removeUnavailable = new FakeGrantAccess(SafGrantStatePolicy.MODE_READ);
        removeUnavailable.failSnapshotAt = 1;
        assertFalse(SafGrantStatePolicy.remove(TARGET_URI, removeUnavailable));
        assertEquals(0, removeUnavailable.releaseCalls);
    }

    @Test
    public void unprovableRollbackFailsAndNeverReleasesPreexistingModes() {
        FakeGrantAccess access = new FakeGrantAccess(SafGrantStatePolicy.MODE_WRITE);
        access.ignoreRelease = true;

        assertFalse(SafGrantStatePolicy.add(
                TARGET_URI,
                SafGrantStatePolicy.MODE_READ | SafGrantStatePolicy.MODE_WRITE,
                TARGET_ID,
                access,
                Collections::emptyList
        ));
        assertEquals(SafGrantStatePolicy.MODE_READ, access.lastReleasedModes);
        assertEquals(
                SafGrantStatePolicy.MODE_READ | SafGrantStatePolicy.MODE_WRITE,
                access.modes
        );
    }

    private static List<DmFileProvider.SafRoot> targetRoots() {
        return Collections.singletonList(new DmFileProvider.SafRoot(
                TARGET_ID,
                "primary:target",
                "Target",
                true
        ));
    }

    private static final class FakeGrantAccess implements SafGrantStatePolicy.GrantAccess {
        boolean treeUri = true;
        boolean duplicateSnapshot;
        boolean leaveWriteOnRelease;
        boolean ignoreRelease;
        int modes;
        int snapshotCalls;
        int failSnapshotAt;
        int takeCalls;
        int releaseCalls;
        int lastReleasedModes;

        FakeGrantAccess(int modes) {
            this.modes = modes;
        }

        @Override
        public boolean targetIsTreeUri() {
            return treeUri;
        }

        @Override
        public List<SafGrantStatePolicy.PersistedGrant> persistedGrants() {
            snapshotCalls += 1;
            if (snapshotCalls == failSnapshotAt) {
                throw new IllegalStateException("redacted test failure");
            }
            if (duplicateSnapshot) {
                return Arrays.asList(
                        new SafGrantStatePolicy.PersistedGrant(
                                TARGET_URI,
                                SafGrantStatePolicy.MODE_READ
                        ),
                        new SafGrantStatePolicy.PersistedGrant(
                                TARGET_URI,
                                SafGrantStatePolicy.MODE_WRITE
                        )
                );
            }
            if (modes == 0) {
                return Collections.emptyList();
            }
            return Collections.singletonList(
                    new SafGrantStatePolicy.PersistedGrant(TARGET_URI, modes)
            );
        }

        @Override
        public void take(int requestedModes) {
            takeCalls += 1;
            modes |= requestedModes;
        }

        @Override
        public void release(int releasedModes) {
            releaseCalls += 1;
            lastReleasedModes = releasedModes;
            if (ignoreRelease) {
                return;
            }
            if (leaveWriteOnRelease) {
                modes &= ~SafGrantStatePolicy.MODE_READ;
                return;
            }
            modes &= ~releasedModes;
        }
    }
}
