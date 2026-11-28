// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// The RPG Maker files sections of a settings form.
struct RTPFilesSections: View {
    @State private var packageToRemove: RTPPackage?

    var body: some View {
        let library = RTPLibrary.shared
        Section {
            ForEach(RTPPackage.allCases) { package in
                RTPPackageRow(
                    name: package.engineName, isInstalled: library.installed.contains(package),
                    onRemove: { packageToRemove = package }
                )
                .disabled(library.isImporting)
            }
        } header: {
            #if os(macOS)
            Text("RPG Maker files")
            #endif
        } footer: {
            Text(
                "Some RPG Maker XP, VX, and VX Ace games need these shared files. All your games use the same copy."
            )
        }
        // `scenePhase` stays `.inactive` under the UIHostingController.
        .task { library.refreshInstalled() }
        .onReceive(NotificationCenter.default.publisher(for: didBecomeActive)) { _ in
            library.refreshInstalled()
        }
        .confirmationDialog(
            "Remove the \(packageToRemove?.engineName ?? "") files?",
            isPresented: Binding {
                packageToRemove != nil
            } set: {
                if !$0 { packageToRemove = nil }
            },
            titleVisibility: .visible,
            presenting: packageToRemove
        ) { package in
            Button("Remove", role: .destructive) { library.remove(package) }
        } message: { _ in
            Text(
                "Games that need them may not start, or pictures and sounds may be missing. You can add them again later."
            )
        }
        Section {
            RTPAddFilesButton()
            Link(destination: EmpoLink.rpgMakerFiles) {
                Label("Download from RPG Maker", systemImage: "arrow.up.forward.app")
            }
        } footer: {
            Text(
                "Download the free files from the RPG Maker website. Then add the .zip or .exe file, or a folder of RPG Maker files from a Windows PC."
            )
        }
    }
}

#if canImport(UIKit)
private let didBecomeActive = UIApplication.didBecomeActiveNotification
#else
private let didBecomeActive = NSApplication.didBecomeActiveNotification
#endif

private struct RTPPackageRow: View {
    let name: String
    let isInstalled: Bool
    let onRemove: () -> Void

    var body: some View {
        LabeledContent {
            if isInstalled {
                Button("Remove", role: .destructive, action: onRemove)
                    .accessibilityLabel(Text("Remove the \(name) files"))
            }
        } label: {
            Text(verbatim: name)
            Text(isInstalled ? "Added" : "Not added")
        }
    }
}

private struct RTPAddFilesButton: View {
    @State private var isPicking = false
    @State private var failure: RTPLibrary.Failure?

    var body: some View {
        let library = RTPLibrary.shared
        Button {
            isPicking = true
        } label: {
            if library.isImporting {
                Label {
                    Text("Adding files…")
                } icon: {
                    ProgressView()
                }
            } else {
                Label("Add files…", systemImage: "plus")
            }
        }
        .disabled(library.isImporting)
        #if os(iOS)
        .sheet(isPresented: $isPicking) {
            DocumentPickerView(contentTypes: RTPLibrary.contentTypes) { urls in
                Task { failure = await library.importFiles(from: urls) }
            }
        }
        #else
        .fileImporter(
            isPresented: $isPicking, allowedContentTypes: RTPLibrary.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): Task { failure = await library.importFiles(from: urls) }
            case .failure(let error): failure = .copy(error.localizedDescription)
            }
        }
        #endif
        .alert(
            failure?.title ?? Text(verbatim: ""),
            isPresented: Binding {
                failure != nil
            } set: {
                if !$0 { failure = nil }
            },
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            failure.message
        }
    }
}

extension RTPLibrary.Failure {
    fileprivate var title: Text {
        switch self {
        case .notRPGMakerFiles, .missingDataFile: Text("Can't use this file")
        case .damaged: Text("This file is incomplete")
        case .noSpace, .copy: Text("Couldn't add the files")
        }
    }

    fileprivate var message: Text {
        switch self {
        case .notRPGMakerFiles:
            Text("Pick the .zip or .exe file from the RPG Maker website, or a folder of RPG Maker files.")
        case .missingDataFile:
            Text("Setup.exe needs Setup-1.bin next to it. Pick the .zip file, or the folder with both files.")
        case .damaged: Text("Download it again from the RPG Maker website, then add it.")
        case .noSpace: Text("This device is full. Free up space, then try again.")
        case .copy(let message): Text(verbatim: message)
        }
    }
}

/// The RPG Maker files on their own screen, for Settings on iOS and for
/// the launch warning.
struct RTPFilesScreen: View {
    var body: some View {
        Form {
            RTPFilesSections()
        }
        .formStyle(.grouped)
        .navigationTitle("RPG Maker files")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct RTPFilesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        NavigationStack {
            RTPFilesScreen()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        SheetBarButton.done { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(.brand)
        #else
        RTPFilesScreen()
            .frame(width: 480)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        #endif
    }
}
