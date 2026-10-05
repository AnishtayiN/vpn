//! One owned Tokio runtime per tunnel, not Aether's process-global FFI runtime.
//! Dropping only run_with's future leaves spawned sockets/tasks alive. Joining
//! this worker shuts down the *entire* runtime before a subsequent start.
use std::collections::BTreeMap;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::Duration;
use tokio::sync::oneshot;

struct Session {
    stop: oneshot::Sender<()>,
    worker: JoinHandle<()>,
}
static SESSION: Mutex<Option<Session>> = Mutex::new(None);
static ERROR: Mutex<String> = Mutex::new(String::new());
static KEYS: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

/// Called on the provider's serial control queue. Never on its packet queue.
#[no_mangle]
pub unsafe extern "C" fn voidrau_core_start(raw: *const c_char) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
        if raw.is_null() { return Err("Missing core configuration".into()); }
        let env: BTreeMap<String, String> = serde_json::from_str(
            CStr::from_ptr(raw).to_str().map_err(|e| e.to_string())?
        ).map_err(|e| e.to_string())?;
        let mut session = SESSION.lock().unwrap_or_else(|p| p.into_inner());
        if session.is_some() { return Err("Core is already running".into()); }
        // Environment changes happen only while our runtime is stopped. No
        // Flutter code or other native engine runs inside this extension.
        let mut keys = KEYS.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap_or_else(|p| p.into_inner());
        for key in keys.drain(..) { std::env::remove_var(key); }
        for (key, value) in env {
            if !key.starts_with("AETHER_") || key.contains(['=', '\0']) || value.contains('\0') {
                return Err("Invalid core environment".into());
            }
            std::env::set_var(&key, value);
            keys.push(key);
        }
        // Packet tunnel extensions have a much smaller memory budget than apps.
        std::env::set_var("AETHER_PERF_PROFILE", "low");
        std::env::set_var("AETHER_NETSTACK_TCP_RX", "16384");
        std::env::set_var("AETHER_NETSTACK_TCP_TX", "16384");
        ERROR.lock().unwrap_or_else(|p| p.into_inner()).clear();
        let (stop, stopped) = oneshot::channel();
        let worker = std::thread::Builder::new().name("voidrau-core".into()).spawn(move || {
            let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
                let rt = tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2).enable_all().build().map_err(|e| e.to_string())?;
                let result = rt.block_on(async {
                    tokio::select! {
                        biased;
                        _ = stopped => Ok(()),
                        r = aether::run_with(Vec::new()) => match r {
                            Ok(()) => Err("Core stopped unexpectedly".into()),
                            Err(e) => Err(e.to_string()),
                        },
                    }
                });
                rt.shutdown_timeout(Duration::from_secs(3));
                result
            }));
            let error = match outcome {
                Ok(Ok(())) => return,
                Ok(Err(e)) => e,
                Err(_) => "Core panicked".into(),
            };
            *ERROR.lock().unwrap_or_else(|p| p.into_inner()) = error;
        }).map_err(|e| e.to_string())?;
        *session = Some(Session { stop, worker });
        Ok(())
    }));
    match result {
        Ok(Ok(())) => 0,
        other => {
            *ERROR.lock().unwrap_or_else(|p| p.into_inner()) = match other {
                Ok(Err(e)) => e,
                _ => "Core initialization panicked".into(),
            };
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn voidrau_core_stop() {
    // Keep the lock until join completes: starting another runtime early is unsafe.
    let mut session = SESSION.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(s) = session.take() {
        let _ = s.stop.send(());
        let _ = s.worker.join();
    }
}

#[no_mangle]
pub extern "C" fn voidrau_core_error() -> *mut c_char {
    CString::new(ERROR.lock().unwrap_or_else(|p| p.into_inner()).replace('\0', " ")).unwrap().into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn voidrau_core_string_free(raw: *mut c_char) {
    if !raw.is_null() { drop(CString::from_raw(raw)); }
}
