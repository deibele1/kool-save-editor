import AppKit

/// The About box: the standard panel with the license notice and disclaimer as credits.
enum AboutPanel {
    static let fullName = "Kool Save Editor for Macintosh"

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: fullName, .credits: credits()])
        NSApp.activate()
    }

    static func credits() -> NSAttributedString {
        let sections: [(String, String)] = [
            ("Derived from GPL software",
             "Named in honor of KSE, the KotOR Savegame Editor (© tk102, FairStrides and the KSE Team). This program is a Swift translation of parts of KSE and of xoreos-tools (the legal property of its developers), both licensed under the GNU GPL version 3 or later. As those licenses require, this program as a whole is distributed under the same terms."),
            ("No copyright claimed",
             "Most of the new code was written by an AI model. The maintainer claims no copyright in this program; copyright in the parts derived from KSE and xoreos-tools remains with their authors."),
            ("No warranty, no liability",
             "Provided “as is”, without warranty of any kind. The maintainer accepts no liability for any damage or loss arising from the use of this program, including damaged or lost saved games. Use it at your own risk."),
            ("Not affiliated",
             "Star Wars, Knights of the Old Republic and KotOR are trademarks of Lucasfilm Ltd. This program is not made, endorsed or supported by Lucasfilm, Disney, BioWare, Obsidian Entertainment, Aspyr Media, the KSE team or the xoreos project."),
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        var heading = body
        heading[.font] = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        heading[.foregroundColor] = NSColor.labelColor

        let text = NSMutableAttributedString()
        for (title, content) in sections {
            text.append(NSAttributedString(string: title + "\n", attributes: heading))
            text.append(NSAttributedString(string: content + "\n\n", attributes: body))
        }

        let links: [(String, URL?)] = [
            ("Full notice", Bundle.main.url(forResource: "NOTICE", withExtension: nil)),
            ("GNU General Public License", Bundle.main.url(forResource: "LICENSE", withExtension: nil)),
            ("KSE", URL(string: "https://gitlab.com/kotorsge-team/kse")),
            ("xoreos-tools", URL(string: "https://github.com/xoreos/xoreos-tools")),
        ]
        for (index, (title, url)) in links.enumerated() {
            guard let url else { continue }
            if index > 0 { text.append(NSAttributedString(string: " · ", attributes: body)) }
            var attributes = body
            attributes[.link] = url
            text.append(NSAttributedString(string: title, attributes: attributes))
        }
        return text
    }
}
