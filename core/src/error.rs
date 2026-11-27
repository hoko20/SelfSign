use std::cell::RefCell;

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Store the message of the most recent failure for `ss_last_error()`.
pub fn set_last_error(message: impl AsRef<str>) {
    let msg = message.as_ref().to_string();
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = msg.clone();
    });
    tracing::error!(target: "selfsign", "{}", msg);
}

/// Take (and clear) the most recent error message.
pub fn take_last_error() -> String {
    LAST_ERROR.with(|cell| std::mem::take(&mut *cell.borrow_mut()))
}

/// Format a `rootcause::Report` into a single readable string including its
/// context chain. isideload reports hide details unless the chain is walked.
pub fn format_report(report: &(impl std::fmt::Display + ?Sized)) -> String {
    report.to_string()
}
