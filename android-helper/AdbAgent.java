package com.adb.toolbox;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;

public final class AdbAgent {

    private static final int PORT = 6000;
    private static final int SOCKET_READ_TIMEOUT_MS = 10_000;
    private static final int CORE_WORKERS = 2;
    private static final int MAX_WORKERS = 4;
    private static final int WORK_QUEUE_CAPACITY = 32;
    private static final int MAX_ICON_SIZE = 96;
    private static final int MAX_PACKAGE_NAME_BYTES = 4_096;
    private static final int APP_LIST_FLUSH_INTERVAL = 20;
    private static final byte[] PROTOCOL_BANNER =
            "SHIRABOX_AGENT/1\n".getBytes(StandardCharsets.US_ASCII);

    private static PackageManager pm;

    private AdbAgent() {
    }

    public static void main(String[] args) {
        ThreadPoolExecutor pool = createWorkerPool();
        try {
            if (Looper.myLooper() == null) {
                Looper.prepare();
            }
            try {
                initContext();
            } catch (Throwable t) {
                t.printStackTrace();
            }

            startStdinMonitor();

            try (ServerSocket serverSocket = new ServerSocket()) {
                serverSocket.setReuseAddress(true);
                serverSocket.bind(
                        new InetSocketAddress(InetAddress.getByName("127.0.0.1"), PORT));
                System.out.println("SERVER_READY");
                System.out.flush();

                while (true) {
                    Socket client = serverSocket.accept();
                    try {
                        client.setTcpNoDelay(true);
                        client.setSoTimeout(SOCKET_READ_TIMEOUT_MS);
                        pool.execute(() -> handleClient(client));
                    } catch (RejectedExecutionException e) {
                        closeQuietly(client);
                    } catch (IOException e) {
                        closeQuietly(client);
                    }
                }
            }
        } catch (Throwable e) {
            e.printStackTrace();
            System.exit(1);
        } finally {
            pool.shutdownNow();
        }
    }

    private static ThreadPoolExecutor createWorkerPool() {
        ThreadPoolExecutor pool = new ThreadPoolExecutor(
                CORE_WORKERS,
                MAX_WORKERS,
                30L,
                TimeUnit.SECONDS,
                new ArrayBlockingQueue<Runnable>(WORK_QUEUE_CAPACITY),
                new ThreadPoolExecutor.AbortPolicy());
        pool.allowCoreThreadTimeOut(true);
        return pool;
    }

    private static void startStdinMonitor() {
        Thread monitor = new Thread(() -> {
            try {
                while (System.in.read() != -1) {
                    // Keep the process alive while the launching adb shell remains attached.
                }
            } catch (IOException ignored) {
                // Treat an input failure like EOF from the launching shell.
            } finally {
                System.exit(0);
            }
        }, "adb-agent-stdin");
        monitor.setDaemon(true);
        monitor.start();
    }

    private static void initContext() throws Exception {
        Class<?> activityThreadClass = Class.forName("android.app.ActivityThread");
        java.lang.reflect.Method systemMainMethod = activityThreadClass.getMethod("systemMain");
        Object activityThread = systemMainMethod.invoke(null);
        java.lang.reflect.Method getSystemContextMethod =
                activityThreadClass.getMethod("getSystemContext");
        Context context = (Context) getSystemContextMethod.invoke(activityThread);
        pm = context.getPackageManager();
    }

    private static void handleClient(Socket socket) {
        try (Socket client = socket;
                DataInputStream in = new DataInputStream(client.getInputStream());
                DataOutputStream out = new DataOutputStream(client.getOutputStream())) {
            try {
                handleRequest(in, out);
            } finally {
                try {
                    out.flush();
                } finally {
                    try {
                        client.shutdownOutput();
                    } catch (IOException ignored) {
                    }
                }
            }
        } catch (EOFException | SocketTimeoutException ignored) {
            // Incomplete and idle requests are closed without occupying a worker indefinitely.
        } catch (IOException e) {
            System.err.println("Client I/O failed: " + e);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    private static void handleRequest(DataInputStream in, DataOutputStream out) throws Exception {
        int type = in.readUnsignedByte();
        switch (type) {
            case 0:
                // Safe capability probe for clients reconnecting to a forwarded port.
                out.write(PROTOCOL_BANNER);
                break;
            case 1:
                sendAppList(out);
                break;
            case 2:
                int length = in.readUnsignedShort();
                if (length == 0 || length > MAX_PACKAGE_NAME_BYTES) {
                    out.writeInt(0);
                    break;
                }
                byte[] packageBytes = new byte[length];
                in.readFully(packageBytes);
                sendAppIcon(out, new String(packageBytes, StandardCharsets.UTF_8));
                break;
            case 3:
                // Retain the legacy ping response for older clients.
                out.writeByte(3);
                break;
            default:
                // Unknown commands receive an empty response followed by EOF.
                break;
        }
    }

    private static void sendAppList(DataOutputStream out) throws Exception {
        try {
            if (pm == null) {
                throw new IllegalStateException("PackageManager is unavailable");
            }

            List<ApplicationInfo> apps =
                    pm.getInstalledApplications(PackageManager.GET_META_DATA);
            int written = 0;
            for (ApplicationInfo app : apps) {
                JSONObject json = new JSONObject();
                json.put("pkg", app.packageName);
                json.put("path", app.sourceDir);

                if (app.splitSourceDirs != null && app.splitSourceDirs.length > 0) {
                    JSONArray splits = new JSONArray();
                    for (String split : app.splitSourceDirs) {
                        splits.put(split);
                    }
                    json.put("splits", splits);
                }

                String label = app.packageName;
                try {
                    CharSequence loadedLabel = app.loadLabel(pm);
                    if (loadedLabel != null) {
                        label = loadedLabel.toString();
                    }
                } catch (Throwable ignored) {
                }

                json.put("name", label.replace('\n', ' ').replace("\r", ""));
                json.put("sys", (app.flags & ApplicationInfo.FLAG_SYSTEM) != 0);
                json.put("en", app.enabled);
                writeJsonLine(out, json);

                written++;
                if (written % APP_LIST_FLUSH_INTERVAL == 0) {
                    out.flush();
                }
            }
        } catch (Exception e) {
            JSONObject error = new JSONObject();
            error.put("pkg", "error");
            error.put("name", "SERVER ERROR: " + e);
            error.put("sys", false);
            error.put("en", true);
            error.put("path", "");
            writeJsonLine(out, error);
            e.printStackTrace();
        } finally {
            // A blank UTF-8 line is the app-list terminator consumed by the Dart client.
            out.writeByte('\n');
            out.flush();
        }
    }

    private static void writeJsonLine(DataOutputStream out, JSONObject json) throws IOException {
        out.write(json.toString().getBytes(StandardCharsets.UTF_8));
        out.writeByte('\n');
    }

    private static void sendAppIcon(DataOutputStream out, String packageName) throws IOException {
        byte[] png = encodeAppIcon(packageName);
        if (png == null) {
            out.writeInt(0);
            return;
        }
        out.writeInt(png.length);
        out.write(png);
    }

    private static byte[] encodeAppIcon(String packageName) {
        Bitmap ownedBitmap = null;
        try {
            if (pm == null) {
                return null;
            }

            ApplicationInfo appInfo = pm.getApplicationInfo(packageName, 0);
            Drawable icon = null;
            try {
                icon = appInfo.loadIcon(pm);
            } catch (Throwable ignored) {
            }
            if (icon == null) {
                icon = pm.getDefaultActivityIcon();
            }

            ownedBitmap = renderToOwnedBitmap(icon);
            if (ownedBitmap == null) {
                return null;
            }

            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            if (!ownedBitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes)) {
                return null;
            }
            return bytes.toByteArray();
        } catch (Throwable ignored) {
            return null;
        } finally {
            if (ownedBitmap != null && !ownedBitmap.isRecycled()) {
                // renderToOwnedBitmap always allocates this bitmap; shared drawable bitmaps
                // are never returned from that method and therefore never recycled here.
                ownedBitmap.recycle();
            }
        }
    }

    private static Bitmap renderToOwnedBitmap(Drawable drawable) {
        if (drawable == null) {
            return null;
        }

        int width = drawable.getIntrinsicWidth();
        int height = drawable.getIntrinsicHeight();
        if (width <= 0 || height <= 0) {
            width = MAX_ICON_SIZE;
            height = MAX_ICON_SIZE;
        }

        double scale = Math.min(1.0d,
                (double) MAX_ICON_SIZE / (double) Math.max(width, height));
        int targetWidth = Math.max(1, (int) Math.round(width * scale));
        int targetHeight = Math.max(1, (int) Math.round(height * scale));

        Bitmap bitmap = null;
        Rect previousBounds = drawable.copyBounds();
        try {
            bitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            drawable.setBounds(0, 0, targetWidth, targetHeight);
            drawable.draw(canvas);
            return bitmap;
        } catch (Throwable ignored) {
            if (bitmap != null && !bitmap.isRecycled()) {
                bitmap.recycle();
            }
            return null;
        } finally {
            drawable.setBounds(previousBounds);
        }
    }

    private static void closeQuietly(Socket socket) {
        try {
            socket.close();
        } catch (IOException ignored) {
        }
    }
}
