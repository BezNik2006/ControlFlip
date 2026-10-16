"""Generate ControlFlip's original icon and the Finder installer background.

Requires Pillow only when regenerating the supplied assets.
"""
from pathlib import Path
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Assets"
ASSETS.mkdir(exist_ok=True)
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, bold=False):
    result = ImageFont.truetype(FONT, round(size))
    if bold:
        try:
            axes = result.get_variation_axes()
            values = [axis["default"] for axis in axes]
            for i, axis in enumerate(axes):
                if axis["name"] == b"Weight":
                    values[i] = 650
            result.set_variation_by_axes(values)
        except (OSError, ValueError):
            pass
    return result


def centered(draw, xy, text, size, fill, bold=False):
    f = font(size, bold)
    box = draw.textbbox((0, 0), text, font=f)
    draw.text((xy[0] - (box[2] - box[0]) / 2, xy[1] - (box[3] - box[1]) / 2 - box[1]), text, font=f, fill=fill)


def app_icon():
    size = 1024
    image = Image.new("RGBA", (size, size))
    mask = Image.new("L", image.size)
    ImageDraw.Draw(mask).rounded_rectangle((66, 58, 958, 950), radius=206, fill=255)
    shadow = Image.new("RGBA", image.size)
    shadow_mask = Image.new("L", image.size)
    ImageDraw.Draw(shadow_mask).rounded_rectangle((76, 84, 948, 963), radius=206, fill=66)
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(22)))
    image.alpha_composite(shadow)
    gradient = Image.new("RGBA", image.size)
    pixels = gradient.load()
    for y in range(size):
        for x in range(size):
            t = min(1, max(0, (y - 58) / 892))
            glow = max(0, 1 - (((x-240)/1000)**2 + ((y-160)/900)**2))
            pixels[x, y] = (round(47-8*t+10*glow), round(144-69*t+9*glow), round(251-27*t), 255)
    gradient.putalpha(mask)
    image.alpha_composite(gradient)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((67,59,957,949), radius=205, outline=(255,255,255,90), width=4)
    # Two keycaps echo the two layouts, with subtle physical depth.
    for rect, radius in [((206,236,526,565),55), ((480,456,800,785),55)]:
        tile_shadow = Image.new("RGBA", image.size)
        ds = ImageDraw.Draw(tile_shadow)
        ds.rounded_rectangle((rect[0],rect[1]+20,rect[2],rect[3]+20), radius=radius, fill=(10,35,112,75))
        image.alpha_composite(tile_shadow.filter(ImageFilter.GaussianBlur(14)))
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((rect[0],rect[1],rect[2],rect[3]+9), radius=radius, fill=(208,225,249,255))
        draw.rounded_rectangle(rect, radius=radius, fill=(249,252,255,255), outline=(255,255,255,255), width=3)
    centered(draw, (366,399), "A", 216, (48,102,219,255), True)
    centered(draw, (640,619), "Я", 207, (48,102,219,255), True)
    # Reciprocal arrows remain clear when the icon is reduced to Finder size.
    draw.line([(609,306),(779,306)], fill=(238,248,255,255), width=17)
    draw.line([(743,269),(780,306),(743,343)], fill=(238,248,255,255), width=17, joint="curve")
    draw.line([(413,723),(244,723)], fill=(238,248,255,255), width=17)
    draw.line([(280,686),(243,723),(280,760)], fill=(238,248,255,255), width=17, joint="curve")
    image.save(ASSETS / "ControlFlip.png")
    image.save(ASSETS / "ControlFlip.icns", format="ICNS")
    iconset = ASSETS / "ControlFlip.iconset"
    iconset.mkdir(exist_ok=True)
    for size in (16,32,128,256,512):
        for scale in (1,2):
            suffix = "@2x" if scale == 2 else ""
            image.resize((size*scale,size*scale), Image.Resampling.LANCZOS).save(iconset/f"icon_{size}x{size}{suffix}.png")
    return image


def installer_background():
    # Finder content area is 760 x 470 pt. A 1x/2x TIFF is made from these PNGs.
    scale = 2
    w, h = 760*scale, 470*scale
    image = Image.new("RGB", (w,h))
    pixels = image.load()
    for y in range(h):
        for x in range(w):
            xx, yy = x/scale, y/scale
            glow = max(0, 1 - (((xx-380)/650)**2+((yy-170)/450)**2))
            pixels[x,y] = (round(249-7*glow), round(251-5*glow), 255)
    d = ImageDraw.Draw(image)
    centered(d,(760,106),"ControlFlip",64,(30,42,66),True)
    centered(d,(760,181),"Правильная раскладка — одним сочетанием",28,(115,128,149))
    # Arrow is part of the background; the app and folder are real Finder items.
    d.line([(666,440),(854,440)], fill=(166,184,210), width=4)
    d.line([(832,418),(854,440),(832,462)], fill=(166,184,210), width=4, joint="curve")
    d.line([(276,678),(1244,678)], fill=(223,231,241), width=2)
    centered(d,(760,746),"Перетащите ControlFlip в папку «Программы»",34,(55,69,92))
    centered(d,(760,822),"После запуска разрешите «Универсальный доступ».",25,(128,141,160))
    image.save(ASSETS/"installer-background@2x.png")
    image.resize((760,470),Image.Resampling.LANCZOS).save(ASSETS/"installer-background.png")
    return image


def preview(background, icon):
    result = background.convert("RGBA")
    result.alpha_composite(icon.resize((256,256),Image.Resampling.LANCZOS),(292,312))
    folder_path = Path(sys.argv[1]) if len(sys.argv)>1 else None
    if folder_path and folder_path.exists():
        folder = Image.open(folder_path).convert("RGBA").resize((256,256),Image.Resampling.LANCZOS)
        result.alpha_composite(folder,(972,312))
        d=ImageDraw.Draw(result)
        d.ellipse((968,490,1038,560),fill=(245,247,250),outline=(206,212,224),width=2)
        centered(d,(1003,522),"↗",58,(50,58,72))
    d=ImageDraw.Draw(result)
    centered(d,(420,600),"ControlFlip",32,(41,48,62))
    centered(d,(1100,600),"Программы",32,(41,48,62))
    result.convert("RGB").save(ASSETS/"Installer-preview.png")


if __name__ == "__main__":
    preview(installer_background(),app_icon())
