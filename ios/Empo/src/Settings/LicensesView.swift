// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct LicensesView: View {
    private let licenses = LicenseEntry.inThisBuild()

    var body: some View {
        List(licenses) { license in
            NavigationLink {
                ScrollView {
                    Text(linkingURLs(in: license.text))
                        .font(.caption)
                        .monospaced()
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .navigationTitle(license.name)
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(license.name)
                    Text(license.license)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Open-source licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func linkingURLs(in text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else {
            return result
        }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                let linkRange = Range(range, in: result)
            else { continue }
            result[linkRange].link = url
        }
        return result
    }
}

struct LicenseEntry: Identifiable, Decodable, Equatable {
    let name: String
    let license: String
    let text: String

    var id: String { name }

    init(_ name: String, license: String, text: String) {
        self.name = name
        self.license = license
        self.text = text
    }

    /// The notices of the app and of each core in this build, one row
    /// for each name. Each core framework carries the licenses.json of
    /// its engine release.
    static func inThisBuild() -> [LicenseEntry] {
        // The four PSDK cores carry the same file.
        let files = Set(
            GameCores.inThisBuild.compactMap { core in
                core.bundle?.url(forResource: "licenses", withExtension: "json").flatMap {
                    try? Data(contentsOf: $0)
                }
            })
        let fromCores = files.flatMap { data -> [LicenseEntry] in
            let entries = (try? JSONDecoder().decode([LicenseEntry].self, from: data)) ?? []
            return entries.map { LicenseEntry($0.name, license: $0.license, text: unwrapped($0.text)) }
        }
        return merged(appLicenses + fromCores)
    }

    /// Two cores can ship the same library at two versions, so a name
    /// keeps each distinct text.
    static func merged(_ entries: [LicenseEntry]) -> [LicenseEntry] {
        Dictionary(grouping: entries, by: \.name).values
            .map { group in
                var seen = Set<String>()
                let texts = group.map(\.text).filter { seen.insert($0).inserted }
                return LicenseEntry(
                    group[0].name, license: group[0].license, text: texts.joined(separator: "\n\n* * *\n\n"))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// License files wrap at about 80 columns, and a phone wraps each of
    /// those lines again. This joins the lines of each paragraph. A line
    /// stays on its own when it starts a list item or a copyright notice,
    /// or has no letter or digit, such as a rule of dashes. A paragraph
    /// that aligns columns with runs of spaces keeps all its lines.
    static func unwrapped(_ text: String) -> String {
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .split(whereSeparator: \.isEmpty)
            .map { lines -> String in
                if lines.contains(where: { $0.contains("   ") }) {
                    return lines.joined(separator: "\n")
                }
                var joined: [String] = []
                var previousStandsAlone = false
                for line in lines {
                    let standsAlone = !line.contains { $0.isLetter || $0.isNumber }
                    if let last = joined.last, !standsAlone, !previousStandsAlone, !startsListItem(line),
                        !line.hasPrefix("Copyright")
                    {
                        joined[joined.count - 1] = last + " " + line
                    } else {
                        joined.append(line)
                    }
                    previousStandsAlone = standsAlone
                }
                return joined.joined(separator: "\n")
            }
        return paragraphs.joined(separator: "\n\n")
    }

    /// "1. ", "- ", "* ", "• ", "a) " or "(iv) ".
    private static func startsListItem(_ line: String) -> Bool {
        guard let space = line.firstIndex(of: " ") else { return false }
        let marker = line[..<space]
        if ["-", "*", "•"].contains(marker) { return true }
        if marker.count > 1, marker.hasSuffix("."), marker.dropLast().allSatisfy(\.isNumber) { return true }
        guard marker.hasSuffix(")") else { return false }
        let label = marker.dropLast().drop { $0 == "(" }
        return (1...3).contains(label.count) && label.allSatisfy { $0.isLowercase || $0.isNumber }
    }
}

// The notices of the code that the app itself ships. Each core brings
// its own. Keep entries alphabetical.
private let appLicenses: [LicenseEntry] = [
    LicenseEntry(
        "ANGLE", license: "BSD 3-Clause",
        text: """
            Copyright 2018 The ANGLE Project Authors. All rights reserved.

            Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

            1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

            2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

            3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
            """),

    LicenseEntry(
        "Empo", license: "GPL-3.0 with additional terms",
        text: """
            Empo, Copyright (C) 2026 Mateo M., https://github.com/mateo-m/empo-app

            This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3, with the additional terms that section 7 of that license permits.

            This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

            The full license is at https://www.gnu.org/licenses/gpl-3.0.html and in the LICENSE file of the source code. The additional terms are in the ADDITIONAL-TERMS.md file of the source code. In short: keep this notice, do not present this program as the work of another person, and give a modified version its own name and icon.

            The name "Empo", the Empo logo, and the Empo icon are not under the GPL.
            """),

    LicenseEntry(
        "fishhook", license: "BSD 3-Clause",
        text: """
            Copyright (c) 2013, Facebook, Inc.
            All rights reserved.

            Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

            * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

            * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

            * Neither the name Facebook nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
            """),

    LicenseEntry(
        "json5pp", license: "MIT",
        text: """
            MIT License

            Copyright (c) 2019 Shuta Kimura

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """),

    LicenseEntry(
        "libarchive", license: "BSD 2-Clause",
        text: """
            Copyright (c) 2003-2018 Tim Kientzle. All rights reserved.

            Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

            1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

            2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

            THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
            """),

    LicenseEntry(
        "libmspack", license: "LGPL 2.1",
        text: """
            Copyright (C) 2003-2023 Stuart Caie.

            libmspack is free software; you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License (LGPL) version 2.1, as published by the Free Software Foundation.

            This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.

            You should have received a copy of the GNU Lesser General Public License along with this library; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA. The full license text is also available at https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html and ships with the source at ios/Empo/vendor/libmspack/COPYING.LIB.
            """),

    LicenseEntry(
        "mimalloc", license: "MIT",
        text: """
            MIT License

            Copyright (c) 2018-2025 Microsoft Corporation, Daan Leijen

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """),

    LicenseEntry(
        "Smallbits icon pack", license: "Smallbits License (free for commercial use)",
        text: """
            Smallbits - 200+ pixelated icons on an 8x8 grid.
            Designed by Minor Adventures (Amsterdam, Netherlands).
            https://smallbits.design

            Used by the splash background's panning pattern. The icons are free for personal and commercial use. The license forbids repackaging them for resale, such as icon marketplaces or UI kits where the icons are the main draw. Empo shows only a small set of shapes: circle, square, diamond, heart, star, plus, cube, and sphere. The full pack ships in `Assets.bundle/SplashIcons/` for later use.

            Smallbits License Agreement (TL;DR):
              "Smallbits is free. Use the icons in personal or commercial projects, modify them however you like, include them in client work and end products. Just don't repackage the icons to sell them as icons - no uploading to marketplaces, no bundling them into UI kits or themes where the icons are the main event, no reselling the files."

            Full terms at https://smallbits.design/license.
            """),

    LicenseEntry(
        "zlib", license: "zlib License",
        text: """
            (C) 1995-2022 Jean-loup Gailly and Mark Adler

            This software is provided 'as-is', without any express or implied warranty.  In no event will the authors be held liable for any damages arising from the use of this software.

            Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

            1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.
            2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.
            3. This notice may not be removed or altered from any source distribution.

            Jean-loup Gailly  Mark Adler
            jloup@gzip.org  madler@alumni.caltech.edu
            """),
]
