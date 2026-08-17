//
//  SettingsTabPage.swift
//  GhostMeet
//

import SwiftUI

/// One page of the settings window: a form, and the scrolling that lands a
/// request from the readiness strip on the control it named.
///
/// **Why the scroll survived the move to tabs.** A tab narrows nine sections
/// down to at most three, which is not the same as down to one: the `sound`
/// page carries the capture backend, the source application and the
/// segmentation thresholds, and a press on «нарезка» that stopped at the top of
/// that page would still leave the user hunting. So a request does two things —
/// `SettingsView` brings this page up, and this page scrolls within itself.
///
/// The split is not stylistic. A page that is not selected has not been laid
/// out, and scrolling to an anchor that has no place yet does nothing at all;
/// the page can only do it once it exists, which is exactly when `onAppear`
/// fires.
struct SettingsTabPage<Content: View>: View {

    let navigation: SettingsNavigation
    let tab: SettingsTab
    @ViewBuilder let content: Content

    /// The last request already scrolled to. Without it, every redraw would drag
    /// the user back to the section they arrived at.
    ///
    /// Per page rather than shared: each page answers only for requests aimed at
    /// it, so there is nothing for them to disagree about.
    @State private var revealed = 0

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                content
            }
            .formStyle(.grouped)
            .onAppear { reveal(with: proxy) }
            .onChange(of: navigation.request) { reveal(with: proxy) }
        }
    }

    /// Scrolls to the section asked for, once per request, and only when the
    /// request is for a section on this page.
    private func reveal(with proxy: ScrollViewProxy) {
        guard let request = navigation.request,
              request.section.tab == tab,
              request.token != revealed else { return }
        revealed = request.token
        // A hop through the main queue on purpose: at `onAppear` the form has
        // not been laid out yet.
        Task { @MainActor in
            withAnimation { proxy.scrollTo(request.section, anchor: .top) }
        }
    }
}
