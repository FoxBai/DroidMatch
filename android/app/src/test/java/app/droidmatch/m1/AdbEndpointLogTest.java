package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import org.junit.Test;

public final class AdbEndpointLogTest {
    @Test
    public void endpointErrorLogLabelOmitsThrowableDetails() {
        String label = AdbEndpoint.EndpointLog.safeErrorLabel(
                "client session failed",
                new IllegalStateException("/storage/emulated/0/DCIM/private.jpg")
        );

        assertEquals("client session failed [IllegalStateException]", label);
        assertFalse(label.contains("/storage/emulated/0"));
        assertFalse(label.contains("private.jpg"));
    }
}
