#!/usr/bin/env python3
"""Export the hand-edited SVG sources to Android, Windows and Linux icons.

Requires librsvg (rsvg-convert) and Pillow; generated icon assets belong in Git.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT/'apps/manager'
ART = APP/'assets/branding'
RES = APP/'android/app/src/main/res'
NS = 'http://schemas.android.com/apk/res/android'
ET.register_namespace('android', NS)


def write(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)


def vector(source, output):
    svg = ET.fromstring(source)
    root = ET.Element('vector', {f'{{{NS}}}{k}': v for k, v in
        dict(width='108dp', height='108dp', viewportWidth='108', viewportHeight='108').items()})
    names = {'d': 'pathData', 'fill': 'fillColor', 'stroke': 'strokeColor',
             'stroke-width': 'strokeWidth', 'stroke-linecap': 'strokeLineCap',
             'stroke-linejoin': 'strokeLineJoin', 'fill-rule': 'fillType'}

    def visit(element, parent):
        if transform := element.get('transform'):
            values = {}
            for operation, args in re.findall(r'(translate|scale)\(([^)]+)\)', transform):
                parts = args.split()
                if operation == 'translate':
                    values.update(translateX=parts[0], translateY=parts[1] if len(parts)>1 else '0')
                else:
                    values.update(scaleX=parts[0], scaleY=parts[-1])
            parent = ET.SubElement(parent, 'group', {f'{{{NS}}}{k}': v for k, v in values.items()})
        if element.tag.endswith('path'):
            attrs = {}
            for k, v in element.attrib.items():
                if k not in names: continue
                if v == 'none': v = '#00000000'
                if v == 'evenodd': v = 'evenOdd'
                attrs[f'{{{NS}}}{names[k]}'] = v
            ET.SubElement(parent, 'path', attrs)
        for child in element: visit(child, parent)

    # Only foreground artwork; the first color SVG path is the background.
    for child in svg:
        if child.tag.endswith('g'): visit(child, root)
    ET.indent(root)
    write(output, '<?xml version="1.0" encoding="utf-8"?>\n'+ET.tostring(root, encoding='unicode')+'\n')


def main():
    color = (ART/'app_icon.svg').read_text()
    mono = (ART/'app_icon_monochrome.svg').read_text()
    vector(color, RES/'drawable/ic_launcher_foreground.xml')
    vector(mono, RES/'drawable/ic_launcher_monochrome.xml')
    write(RES/'values/icon_colors.xml', '<resources>\n    <color name="ic_launcher_background">#111D23</color>\n</resources>\n')
    for version in (26, 33):
        themed = '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n' if version == 33 else ''
        write(RES/f'mipmap-anydpi-v{version}/ic_launcher.xml',
              '<?xml version="1.0" encoding="utf-8"?>\n'
              f'<adaptive-icon xmlns:android="{NS}">\n'
              '    <background android:drawable="@color/ic_launcher_background" />\n'
              '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'+themed+'</adaptive-icon>\n')
    # Legacy/desktop icons use their own rounded background and a tighter crop.
    desktop = color.replace('viewBox="0 0 108 108"', 'viewBox="16 16 76 76"')
    desktop = desktop.replace('<path fill="#111D23" d="M0 0 H108 V108 H0 Z"/>',
                              '<rect x="16" y="16" width="76" height="76" rx="18" fill="#111D23"/>')
    with tempfile.TemporaryDirectory(prefix='antirkn-icons-') as temporary:
        png = Path(temporary)/'icon.png'
        subprocess.run(['rsvg-convert', '-w', '1024', '-h', '1024', '-o', str(png)],
                       input=desktop.encode(), check=True)
        im = Image.open(png)
        for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
            im.resize((size,size), Image.Resampling.LANCZOS).save(RES/f'mipmap-{density}/ic_launcher.png')
        im.save(APP/'windows/runner/resources/app_icon.ico', sizes=[(s,s) for s in (16,24,32,48,64,128,256)])
        im.resize((256,256), Image.Resampling.LANCZOS).save(ART/'app_icon.png')
    print('Android adaptive/monochrome/legacy, Windows ICO, Linux PNG: generated')


if __name__ == '__main__': main()
