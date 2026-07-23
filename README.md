# EXIF Stamp — плагин для Lightroom Classic

Добавляет мелким шрифтом EXIF (камера, объектив, параметры съёмки) в выбранный угол фото при экспорте.

## Требования

- macOS, ImageMagick с freetype: `brew install imagemagick`

## Установка

1. Lightroom Classic → File → Plug-in Manager → Add
2. Выбрать папку `ExifStamp.lrplugin`

## Использование

1. File → Export
2. Внизу в «Post-Process Actions» дважды кликнуть «EXIF Stamp»
3. В появившейся секции выбрать угол, размер, цвет и состав надписи
4. Export

Надпись накладывается только на JPEG/PNG/TIFF. Файлы без EXIF экспортируются без надписи.

## Отладка

Логи: `~/Documents/lrClassicLogs/ExifStamp.log`
