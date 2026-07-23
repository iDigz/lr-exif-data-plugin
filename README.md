# EXIF Stamp — плагин для Lightroom Classic

Добавляет мелким шрифтом EXIF (камера, объектив, параметры съёмки) в выбранный угол фото при экспорте.

## Требования

- macOS
- ImageMagick (с freetype) и exiftool: `brew install imagemagick exiftool`

exiftool нужен, чтобы получить полные имена камеры и объектива из оригинального
файла: Lightroom отдаёт только короткое имя объектива («RF24-70mm F2.8 L IS USM»),
а exiftool — полное («Canon RF 24-70mm F2.8L IS USM»).

## Установка

1. Lightroom Classic → File → Plug-in Manager → Add
2. Выбрать папку `ExifStamp.lrplugin`

## Использование

1. File → Export
2. Внизу в «Post-Process Actions» дважды кликнуть «EXIF Stamp»
3. В появившейся секции выбрать угол, размер, шрифт, цвет и состав надписи.
   Внизу — живой предпросмотр на выделенном фото, обновляется при смене настроек.
4. Export

Надпись накладывается только на JPEG/PNG/TIFF. Файлы без EXIF экспортируются без надписи.

## Отладка

Логи: `~/Documents/lrClassicLogs/ExifStamp.log`
