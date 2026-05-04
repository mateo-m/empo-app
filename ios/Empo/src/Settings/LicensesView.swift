import SwiftUI

struct LicensesView: View {
    var body: some View {
        List(licenses) { license in
            NavigationLink {
                ScrollView {
                    Text(license.text)
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
}

private struct LicenseEntry: Identifiable {
    let id: String
    let name: String
    let license: String
    let text: String

    init(_ name: String, license: String, text: String) {
        self.id = name
        self.name = name
        self.license = license
        self.text = text
    }
}

// Keep entries alphabetical.
private let licenses: [LicenseEntry] = [
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
        "FreeType", license: "FreeType License (FTL)",
        text: """
            Copyright (C) 2006-2023 by David Turner, Robert Wilhelm, and Werner Lemberg.

            This software is provided 'as-is', without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

            Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

            1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.

            2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.

            3. This notice may not be removed or altered from any source distribution.
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
        "libogg", license: "BSD 3-Clause",
        text: """
            Copyright (c) 2002, Xiph.org Foundation

            Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

            1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

            2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

            3. Neither the name of the Xiph.org Foundation nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
            """),

    LicenseEntry(
        "libpng", license: "libpng License",
        text: """
            Copyright (c) 1998-2023 Glenn Randers-Pehrson

            This code is released under the libpng license. For conditions of distribution and use, see the disclaimer and license in png.h.

            The PNG Reference Library is supplied "AS IS". The Contributing Authors and Group 42, Inc. disclaim all warranties, expressed or implied, including, without limitation, the warranties of merchantability and of fitness for any particular purpose. The Contributing Authors and Group 42, Inc. assume no liability for direct, indirect, incidental, special, exemplary, or consequential damages, which may result from the use of the PNG Reference Library, even if advised of the possibility of such damage.
            """),

    LicenseEntry(
        "libtheora", license: "BSD 3-Clause",
        text: """
            Copyright (C) 2002-2009 Xiph.org Foundation

            Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

            1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

            2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

            3. Neither the name of the Xiph.org Foundation nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
            """),

    LicenseEntry(
        "libvorbis", license: "BSD 3-Clause",
        text: """
            Copyright (c) 2002-2020 Xiph.org Foundation

            Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

            1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

            2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

            3. Neither the name of the Xiph.org Foundation nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
            """),

    LicenseEntry(
        "mkxp-z", license: "GPL-2.0",
        text: """
            mkxp-z - RGSS player for multiple platforms
            Copyright (C) 2020-2024 Splendide Imaginarius and contributors
            Copyright (C) 2013-2023 Jonas Kulla and contributors

            This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

            This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

            You should have received a copy of the GNU General Public License along with this program; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
            """),

    LicenseEntry(
        "PhysicsFS", license: "zlib License",
        text: """
            Copyright (c) 2001-2022 Ryan C. Gordon and contributors.

            This software is provided 'as-is', without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

            Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

            1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.

            2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.

            3. This notice may not be removed or altered from any source distribution.
            """),

    LicenseEntry(
        "pixman", license: "MIT",
        text: """
            Copyright 1987, 1988, 1989, 1998 The Open Group
            Copyright 1987, 1988, 1989 Digital Equipment Corporation
            Copyright 1999, 2004, 2008 Keith Packard
            Copyright 2000 SuSE, Inc.
            Copyright 2000 Keith Packard, member of The XFree86 Project, Inc.
            Copyright 2004, 2005, 2007, 2008, 2009, 2010 Red Hat, Inc.
            Copyright 2004 Nicholas Miell
            Copyright 2005 Lars Knoll & Zack Rusin, Trolltech
            Copyright 2005 Trolltech AS
            Copyright 2007 Luca Barbato
            Copyright 2008 Aaron Plattner, NVIDIA Corporation
            Copyright 2008 Rodrigo Kumpera
            Copyright 2008 Andre Tupinamba
            Copyright 2008 Mozilla Corporation
            Copyright 2008, 2009, 2010 Nokia Corporation
            Copyright 2009, 2010 Jeff Muizelaar
            Copyright 2009, 2010 Siarhei Siamashka
            Copyright 2009 Mans Rullgard
            Copyright 2011 Samsung Electronics

            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """),

    LicenseEntry(
        "Ruby", license: "Ruby License / BSD 2-Clause",
        text: """
            Ruby is copyrighted free software by Yukihiro Matsumoto <matz@netlab.jp>.

            You can redistribute it and/or modify it under either the terms of the 2-clause BSDL (see the file BSDL), or the conditions below:

            1. You may make and give away verbatim copies of the source form of the software without restriction, provided that you duplicate all of the original copyright notices and associated disclaimers.

            2. You may modify your copy of the software in any way, provided that you do at least ONE of the following:

               a) place your modifications in the Public Domain or otherwise make them Freely Available, such as by posting said modifications to Usenet or an equivalent medium, or by allowing the author to include your modifications in the software.

               b) use the modified software only within your corporation or organization.

               c) give non-standard binaries non-standard names, with instructions on where to get the original software distribution.

               d) make other distribution arrangements with the author.
            """),

    LicenseEntry(
        "Smallbits icon pack", license: "Smallbits License (free for commercial use)",
        text: """
            Smallbits - 200+ pixelated icons on an 8x8 grid.
            Designed by Minor Adventures (Amsterdam, Netherlands).
            https://smallbits.design

            Used by the splash background's panning pattern. The icons are free for personal and commercial use; the license forbids repackaging them for resale (icon marketplaces, UI kits where the icons are the main draw, etc.). We embed only a curated subset (geometric primitives - circle, square, diamond, heart, star, plus, cube, sphere) and the full pack ships in `Assets.bundle/SplashIcons/` for use in future surfaces.

            Smallbits License Agreement (TL;DR):
              "Smallbits is free. Use the icons in personal or commercial projects, modify them however you like, include them in client work and end products. Just don't repackage the icons to sell them as icons - no uploading to marketplaces, no bundling them into UI kits or themes where the icons are the main event, no reselling the files."

            Full terms at https://smallbits.design/license.
            """),

    LicenseEntry(
        "SDL2", license: "zlib License",
        text: """
            Copyright (C) 1997-2024 Sam Lantinga <slouken@libsdl.org>

            This software is provided 'as-is', without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

            Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

            1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.

            2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.

            3. This notice may not be removed or altered from any source distribution.
            """),

    LicenseEntry(
        "SDL2_image", license: "zlib License",
        text: """
            Copyright (C) 1997-2024 Sam Lantinga <slouken@libsdl.org>

            This software is provided 'as-is', without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

            Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

            1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.

            2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.

            3. This notice may not be removed or altered from any source distribution.
            """),

    LicenseEntry(
        "SDL2_sound", license: "zlib License",
        text: """
            Copyright (C) 2001-2024 Ryan C. Gordon <icculus@icculus.org>

            This software is provided 'as-is', without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

            Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

            1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.

            2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.

            3. This notice may not be removed or altered from any source distribution.
            """),

    LicenseEntry(
        "SDL2_ttf", license: "zlib License",
        text: """
            Copyright (C) 1997-2024 Sam Lantinga <slouken@libsdl.org>

            This software is provided 'as-is', without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

            Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

            1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.

            2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.

            3. This notice may not be removed or altered from any source distribution.
            """),

    LicenseEntry(
        "uchardet", license: "MPL 1.1 / GPL 2.0 / LGPL 2.1",
        text: """
            Copyright (C) 2006 via BYTEmark International

            The contents of this file are subject to the Mozilla Public License Version 1.1 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.mozilla.org/MPL/

            Software distributed under the License is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License for the specific language governing rights and limitations under the License.

            Alternatively, the contents of this file may be used under the terms of either the GNU General Public License Version 2 or later (the "GPL"), or the GNU Lesser General Public License Version 2.1 or later (the "LGPL"), in which case the provisions of the GPL or the LGPL are applicable instead of those above.
            """),
]
