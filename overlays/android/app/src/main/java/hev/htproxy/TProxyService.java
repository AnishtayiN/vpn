package hev.htproxy;

/**
 * JNI binding for heiher/hev-socks5-tunnel.
 * Signatures must match src/hev-jni.c (boolean start/stop/running).
 */
public final class TProxyService {
    private TProxyService() {}

    static {
        System.loadLibrary("hev-socks5-tunnel");
    }

    public static native boolean TProxyStartService(String config_path, int fd);

    public static native boolean TProxyStopService();

    public static native boolean TProxyIsRunning();

    public static native long[] TProxyGetStats();
}
