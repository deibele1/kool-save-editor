import KotORSave
import SwiftUI

struct PartyView: View {
    let document: SaveDocument

    var body: some View {
        if let save = document.save {
            Form {
                Section("Resources") {
                    NumberField(title: "Credits", value: document.binding("Change Credits", { $0.credits }, { $0.credits = $1 }), step: 100)
                    NumberField(title: "Party experience", value: document.binding("Change Party Experience", { $0.partyExperience }, { $0.partyExperience = $1 }),
                                step: 100, help: "Experience waiting to be shared out (PT_XP_POOL).")
                    if save.components != nil {
                        NumberField(title: "Components", value: document.binding("Change Components", { $0.components ?? 0 }, { $0.components = $1 }))
                    }
                    if save.chemicals != nil {
                        NumberField(title: "Chemicals", value: document.binding("Change Chemicals", { $0.chemicals ?? 0 }, { $0.chemicals = $1 }))
                    }
                }

                Section {
                    let members = save.partyMembers
                    let current = Set(save.partyMemberIDs)
                    ForEach(members) { member in
                        Toggle(isOn: Binding(
                            get: { current.contains(member.index) },
                            set: { isOn in
                                var ids = save.partyMemberIDs.filter { $0 != member.index }
                                if isOn { ids.append(member.index) }
                                document.edit("Change Party") { $0.setPartyMembers(ids) }
                            })) {
                            HStack {
                                Text(document.companionName(member.index))
                                if let note = note(for: member) {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!save.canToggleCompanion(member.index)
                                  || (!current.contains(member.index) && current.count >= SaveGame.maximumPartySize))
                    }
                } header: {
                    Text("Active Party")
                } footer: {
                    Text(partyFooter(save)).foregroundStyle(.secondary)
                }

                if save.supportsInfluence {
                    Section {
                        ForEach(save.partyMembers) { member in
                            InfluenceRow(document: document, index: member.index, title: document.companionName(member.index))
                        }
                    } header: {
                        Text("Influence")
                    } footer: {
                        Text("Influence can be set for every companion, whether or not they have joined yet. 0 is the lowest and 100 the highest the game uses.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func note(for member: PartyMember) -> String? {
        if member.isControlled { return "You’re playing as this companion" }
        if !member.isAvailable { return "Not available" }
        return member.isSelectable ? nil : "Locked by the story"
    }

    private func partyFooter(_ save: SaveGame) -> String {
        if let controlled = save.controlledCompanion {
            return "You’re playing as \(document.companionName(controlled)) at this point in the story, so the party can’t be changed until the game switches back to your character."
        }
        if save.isSoloMode {
            return "The story has your character going on alone at this point, so the party can’t be changed."
        }
        if !save.canChangeParty {
            return "You’re playing as a companion at this point in the story, so the party can’t be changed until the game switches back to your character."
        }
        let locked = save.partyMembers.contains { $0.isAvailable && !$0.isSelectable }
        return "Up to two available companions travel with the player." + (locked ? " Companions the story has locked can’t be added or removed." : "")
    }
}
