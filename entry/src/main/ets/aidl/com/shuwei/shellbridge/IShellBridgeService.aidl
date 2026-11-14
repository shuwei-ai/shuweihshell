/*
 * The AIDL interface other apps call.
 *
 * The shape deliberately mirrors Shizuku's IShizukuService so that anyone
 * who has integrated Shizuku finds the same concepts here: the service
 * reports the uid it runs commands as and lets the user grant or revoke
 * access per app.
 *
 * Every argument is a string.  That keeps the interface identical for the
 * two RPC entry points HarmonyOS offers (MessageParcel before HarmonyOS 6,
 * MessageSequence from HarmonyOS 6 on), so the service can identify the
 * caller by access token where the runtime provides one and by the bundle
 * name it declares otherwise.
 */
package com.shuwei.shellbridge;

interface IShellBridgeService {
    /** Checks whether the bridge service is running and responsive. */
    boolean pingBinder();

    /** The bridge's own version. */
    int getVersion();

    /**
     * The uid the commands run as.  This is 2000 (shell) - the same level the
     * device's own hdc shell gives.
     */
    int getUid();

    /** The SELinux context the commands run in. */
    String getSelinuxContext();

    /** Runs a command and returns its standard output. */
    String exec(String command, String caller);

    /** Runs a command and returns a JSON result. */
    String execWithResult(String command, String caller);

    /** Whether the calling app currently holds the use permission. */
    boolean checkSelfPermission(String caller);

    /** Asks the user to grant the calling app the use permission. */
    void requestPermission(String requestCode, String caller);

    /** Asks the service to shut down. */
    void exit();
}
