# Third-party notices

Smart Dimmer bundles the following third-party components. Their licences are reproduced below and
in `src/lib/`.

## WebView2 binding for AutoHotkey v2 (`src/lib/WebView2.ahk`, `Promise.ahk`, `ComVar.ahk`)

By thqby, from <https://github.com/thqby/ahk2_lib>. MIT License.
The `#Include` lines were changed to load `ComVar.ahk` and `Promise.ahk` from the same folder;
nothing else was modified.

```
MIT License

Copyright (c) 2023 thqby

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Microsoft Edge WebView2 loader (`src/lib/WebView2Loader.dll`)

From the Microsoft.Web.WebView2 NuGet package (1.0.4191.47), 64-bit loader. The compiled
`SmartDimmer.exe` embeds this file and extracts it next to itself on first start.

```
Copyright (C) Microsoft Corporation. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * The name of Microsoft Corporation, or the names of its contributors
may not be used to endorse or promote products derived from this
software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## AutoHotkey v2

The compiled executable contains the AutoHotkey v2 interpreter (`AutoHotkey64.exe` base file),
licensed under the GNU General Public License v2.0: <https://www.autohotkey.com/docs/v2/license.htm>.
AutoHotkey is not modified; the script and the page remain under the MIT License above.

## Theme palettes

The *Tokyo Night* and *Nord Frost* themes are inspired by the colour palettes of the
[Tokyo Night](https://github.com/enkia/tokyo-night-vscode-theme) (MIT) and [Nord](https://www.nordtheme.com/)
(MIT) projects. Smart Dimmer is not affiliated with either project.

## Weather and place search

The automatic theme and the Sky theme use the free [Open-Meteo](https://open-meteo.com/) weather
forecast and geocoding APIs. Weather data by Open-Meteo.com, licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Place names come from GeoNames via Open-Meteo.
Nothing from these services is bundled; they are called only while those features are in use.

## Microsoft Edge WebView2 Runtime

Not bundled. The application uses the Evergreen WebView2 Runtime installed on the machine
(shipped with Windows 10/11 updates). Download if missing:
<https://developer.microsoft.com/microsoft-edge/webview2/>.
