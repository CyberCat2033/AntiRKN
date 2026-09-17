package org.antirkn.antirkn_manager;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.app.Instrumentation;
import android.app.Activity;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Exercises the installed release's real JNI service, without user data. */
public class MihomoRuntimeTest extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            testXHTTPNumericRanges();
            testValidationThenDirectTrafficInFreshProcess();
            result.putString("stream", "PASS: XHTTP numeric options, JNI validation, fresh process, HTTPS and UDP\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "FAIL: " + error.getClass().getSimpleName() + ": " + error.getMessage() + "\n");
            finish(Activity.RESULT_CANCELED, result);
        }
    }
    private static void assertTrue(String message, boolean value) { if (!value) throw new AssertionError(message); }
    private static void assertTrue(boolean value) { assertTrue("expected true", value); }
    private static void assertNull(String message, Object value) { assertTrue(message, value == null); }
    private static void assertNotNull(String message, Object value) { assertTrue(message, value != null); }
    private static void assertEquals(String message, String expected, String value) { assertTrue(message, expected.equals(value)); }
    private static void assertEquals(String expected, String value) { assertEquals("expected " + expected + ", got " + value, expected, value); }
    private JSONObject execute(JSONObject request) throws Exception {
        Context context = getTargetContext();
        File directory = new File(context.getCacheDir(), "mihomo-instrumentation-" + System.nanoTime());
        assertTrue(directory.mkdir());
        File input = new File(directory, "request.json");
        try (FileOutputStream out = new FileOutputStream(input)) {
            out.write(request.toString().getBytes(StandardCharsets.UTF_8));
        }
        CountDownLatch replied = new CountDownLatch(1), died = new CountDownLatch(1);
        AtomicReference<String> response = new AtomicReference<>();
        AtomicReference<Throwable> error = new AtomicReference<>();
        Messenger reply = new Messenger(new Handler(Looper.getMainLooper()) {
            @Override public void handleMessage(Message message) {
                response.set(message.getData().getString("result"));
                replied.countDown();
            }
        });
        ServiceConnection connection = new ServiceConnection() {
            @Override public void onServiceConnected(ComponentName name, IBinder binder) {
                try {
                    binder.linkToDeath(died::countDown, 0);
                    Message message = Message.obtain(null, 1);
                    message.replyTo = reply;
                    Bundle data = new Bundle();
                    data.putString("path", input.getPath());
                    message.setData(data);
                    new Messenger(binder).send(message);
                } catch (Throwable failure) { error.set(failure); replied.countDown(); }
            }
            @Override public void onServiceDisconnected(ComponentName name) { died.countDown(); }
        };
        Intent intent = new Intent().setClassName(context,
            "org.antirkn.antirkn_manager.MihomoValidationService");
        boolean bound = false;
        try {
            bound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE);
            assertTrue("service binding", bound);
            assertTrue("worker reply", replied.await(20, TimeUnit.SECONDS));
            assertNull("binder failure", error.get());
            assertNotNull("JNI returned no result", response.get());
            assertTrue("worker must exit after every request", died.await(3, TimeUnit.SECONDS));
            JSONObject result = new JSONObject(response.get());
            assertEquals("1.19.30", result.getString("version"));
            return result;
        } finally {
            if (bound) context.unbindService(connection);
            remove(directory);
        }
    }

    private void remove(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) remove(child);
        file.delete();
    }

    public void testValidationThenDirectTrafficInFreshProcess() throws Exception {
        JSONObject validation = execute(new JSONObject().put("yaml", "proxies: []\nrules:\n  - MATCH,DIRECT\n"));
        assertEquals(validation.toString(), "valid", validation.getString("status"));
        JSONObject traffic = execute(new JSONObject().put("mode", "control").put("yaml", "{}").put("udp", true));
        assertEquals(traffic.toString(), "success", traffic.getString("status"));
        assertTrue(traffic.getBoolean("tcp"));
        assertTrue(traffic.getBoolean("udp"));
    }

    private void testXHTTPNumericRanges() throws Exception {
        JSONObject options = new JSONObject().put("mode", "packet-up")
            .put("x-padding-bytes", 100).put("sc-max-each-post-bytes", 1000000)
            .put("reuse-settings", new JSONObject().put("max-connections", 3));
        JSONObject proxy = new JSONObject().put("name", "fixture").put("type", "vless")
            .put("server", "127.0.0.1").put("port", 1)
            .put("uuid", "00000000-0000-4000-8000-000000000001")
            .put("network", "xhttp").put("xhttp-opts", options);
        JSONObject result = execute(new JSONObject().put("mode", "probe").put("yaml", proxy.toString()));
        // A closed local port must fail the connection, not reject valid options.
        assertEquals(result.toString(), "connection_failed", result.getString("code"));
        assertTrue(!result.getBoolean("tcp"));
    }
}
