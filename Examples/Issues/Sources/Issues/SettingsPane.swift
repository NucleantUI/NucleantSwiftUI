//
//  SettingsPane.swift
//  Issues
//
//  Settings, as a `Form` in the desktop's `.columns` style: every control's
//  label in one column against its trailing edge, the controls lined up
//  beside them, and each section's header beside its first row. Changes
//  apply at once — the sidebar's badges, which issues the lists show, how
//  the Updated column writes dates.
//

import NucleantUI

@View
struct SettingsPane {
    @Bindable var preferences: Preferences
    let people: [Person]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 22, weight: .semibold))
                    Text("For this tracker, on this Mac.")
                        .foregroundColor(.secondary)
                }
                Form {
                    Section("Account:") {
                        Picker("Signed in as:", selection: $preferences.me) {
                            ForEach(people) { person in
                                Text(person.name).tag(person)
                            }
                        }
                    }
                    Section("New issues:") {
                        Picker("Priority:", selection: $preferences.defaultPriority) {
                            ForEach(Priority.allCases) { priority in
                                Text(priority.name)
                            }
                        }
                        .pickerStyle(.segmented)
                        Stepper(
                            "Estimate: \(preferences.defaultPoints) points",
                            value: $preferences.defaultPoints,
                            in: 0...13
                        )
                    }
                    Section("Lists:") {
                        Toggle("Show canceled issues", isOn: $preferences.showsCanceled)
                        Toggle("Show counts in the sidebar", isOn: $preferences.showsBadges)
                        Picker("Dates:", selection: $preferences.dateStyle) {
                            ForEach(Preferences.DateStyle.allCases) { style in
                                Text(style.name)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    }
                    Section {
                        LabeledContent("Version:", value: "1.0")
                    } footer: {
                        Text("An example app for NucleantUI's List, Section, Form, OutlineGroup and Table.")
                    }
                }
                .formStyle(.columns)
            }
            .padding(32)
            .frame(maxWidth: 620, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.secondaryBackground)
    }
}
