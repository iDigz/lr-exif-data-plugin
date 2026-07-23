-- Export filter: stamps EXIF info (camera, lens, exposure) onto exported photos
-- using ImageMagick. The rendered file is modified in place after Lightroom
-- finishes rendering it.

local LrView = import 'LrView'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrDialogs = import 'LrDialogs'
local LrLogger = import 'LrLogger'

local logger = LrLogger('ExifStamp')
logger:enable('logfile')

local bind = LrView.bind

local MAGICK_CANDIDATES = {
	'/opt/homebrew/bin/magick',
	'/usr/local/bin/magick',
}

local FONT_CANDIDATES = {
	'/System/Library/Fonts/Helvetica.ttc',
	'/System/Library/Fonts/Monaco.ttf',
}

local SUPPORTED_EXTENSIONS = { jpg = true, jpeg = true, png = true, tif = true, tiff = true }

local ExifStampFilter = {}

ExifStampFilter.exportPresetFields = {
	{ key = 'exifstamp_corner', default = 'SouthEast' },
	{ key = 'exifstamp_size', default = 18 },        -- text height, 1/1000 of image height
	{ key = 'exifstamp_color', default = 'white' },
	{ key = 'exifstamp_showCamera', default = true },
	{ key = 'exifstamp_showLens', default = true },
	{ key = 'exifstamp_showFocal', default = true },
	{ key = 'exifstamp_showAperture', default = true },
	{ key = 'exifstamp_showShutter', default = true },
	{ key = 'exifstamp_showIso', default = true },
}

local function findExistingFile( candidates )
	for _, path in ipairs( candidates ) do
		if LrFileUtils.exists( path ) then
			return path
		end
	end
	return nil
end

local function isSupportedFile( path )
	local extension = string.lower( LrPathUtils.extension( path ) or '' )
	return SUPPORTED_EXTENSIONS[ extension ] == true
end

-- Lightroom formats metadata with extra spaces and words ("f / 5.6", "1/250 sec").
-- Normalize to a compact form: "f/5.6", "1/250s", "35mm".
local function cleanAperture( value )
	if not value then return nil end
	value = string.gsub( value, 'ƒ', 'f' )
	value = string.gsub( value, '%s*/%s*', '/' )
	return value
end

local function cleanShutter( value )
	if not value then return nil end
	value = string.gsub( value, '%s*sec%.?$', 's' )
	return value
end

local function cleanFocal( value )
	if not value then return nil end
	value = string.gsub( value, '%s*mm$', 'mm' )
	return value
end

local function buildStampText( photo, settings )
	local parts = {}

	local function add( enabled, value )
		if enabled and value and value ~= '' then
			parts[ #parts + 1 ] = value
		end
	end

	add( settings.exifstamp_showCamera, photo:getFormattedMetadata( 'cameraModel' ) )
	add( settings.exifstamp_showLens, photo:getFormattedMetadata( 'lens' ) )
	add( settings.exifstamp_showFocal, cleanFocal( photo:getFormattedMetadata( 'focalLength' ) ) )
	add( settings.exifstamp_showAperture, cleanAperture( photo:getFormattedMetadata( 'aperture' ) ) )
	add( settings.exifstamp_showShutter, cleanShutter( photo:getFormattedMetadata( 'shutterSpeed' ) ) )
	add( settings.exifstamp_showIso, photo:getFormattedMetadata( 'isoSpeedRating' ) )

	return table.concat( parts, ' · ' )
end

-- Wrap text in single quotes for /bin/sh: ' becomes '\''
local function shellQuote( text )
	return "'" .. string.gsub( text, "'", "'\\''" ) .. "'"
end

local function stampPhoto( magick, fontPath, filePath, text, settings )
	local fillColor, strokeColor
	if settings.exifstamp_color == 'black' then
		fillColor, strokeColor = 'black', 'white'
	else
		fillColor, strokeColor = 'white', 'black'
	end

	local size = tonumber( settings.exifstamp_size ) or 18
	local gravity = settings.exifstamp_corner or 'SouthEast'
	local quotedPath = '"' .. filePath .. '"'
	local quotedText = shellQuote( text )

	-- One shell line: measure image height, derive point size, padding and
	-- stroke width, then draw the text twice (outline pass + fill pass).
	local command = string.format(
		'H=$(%s identify -format %%h %s); P=$((H*%d/1000)); [ "$P" -lt 8 ] && P=8; S=$((P/12+1)); '
		.. '%s %s -gravity %s -font "%s" -pointsize "$P" '
		.. '-stroke %s -strokewidth "$S" -fill %s -annotate "+$P+$P" %s '
		.. '-stroke none -fill %s -annotate "+$P+$P" %s %s',
		magick, quotedPath, size,
		magick, quotedPath, gravity, fontPath,
		strokeColor, fillColor, quotedText,
		fillColor, quotedText, quotedPath
	)

	logger:trace( 'exec: ' .. command )
	local exitCode = LrTasks.execute( command )
	if exitCode ~= 0 then
		logger:error( 'magick failed with code ' .. tostring( exitCode ) .. ' for ' .. filePath )
	end
	return exitCode == 0
end

function ExifStampFilter.sectionForFilterInDialog( f, propertyTable )
	return {
		title = 'EXIF Stamp',

		f:column {
			bind_to_object = propertyTable,
			spacing = f:control_spacing(),

			f:row {
				f:static_text { title = 'Угол:', width = LrView.share 'exifstamp_label' },
				f:popup_menu {
					value = bind 'exifstamp_corner',
					items = {
						{ title = 'Правый нижний', value = 'SouthEast' },
						{ title = 'Левый нижний', value = 'SouthWest' },
						{ title = 'Правый верхний', value = 'NorthEast' },
						{ title = 'Левый верхний', value = 'NorthWest' },
					},
				},
			},

			f:row {
				f:static_text { title = 'Размер:', width = LrView.share 'exifstamp_label' },
				f:popup_menu {
					value = bind 'exifstamp_size',
					items = {
						{ title = 'Мелкий', value = 12 },
						{ title = 'Средний', value = 18 },
						{ title = 'Крупный', value = 25 },
					},
				},
			},

			f:row {
				f:static_text { title = 'Цвет:', width = LrView.share 'exifstamp_label' },
				f:popup_menu {
					value = bind 'exifstamp_color',
					items = {
						{ title = 'Белый с тёмной обводкой', value = 'white' },
						{ title = 'Чёрный со светлой обводкой', value = 'black' },
					},
				},
			},

			f:row {
				f:static_text { title = 'Показывать:', width = LrView.share 'exifstamp_label' },
				f:column {
					spacing = f:label_spacing(),
					f:row {
						f:checkbox { title = 'Камера', value = bind 'exifstamp_showCamera' },
						f:checkbox { title = 'Объектив', value = bind 'exifstamp_showLens' },
						f:checkbox { title = 'Фокусное', value = bind 'exifstamp_showFocal' },
					},
					f:row {
						f:checkbox { title = 'Диафрагма', value = bind 'exifstamp_showAperture' },
						f:checkbox { title = 'Выдержка', value = bind 'exifstamp_showShutter' },
						f:checkbox { title = 'ISO', value = bind 'exifstamp_showIso' },
					},
				},
			},
		},
	}
end

function ExifStampFilter.postProcessRenderedPhotos( functionContext, filterContext )
	local settings = filterContext.propertyTable

	local magick = findExistingFile( MAGICK_CANDIDATES )
	local fontPath = findExistingFile( FONT_CANDIDATES )
	local errorShown = false

	for sourceRendition, renditionToSatisfy in filterContext:renditions() do
		local success, pathOrMessage = sourceRendition:waitForRender()

		if success then
			local filePath = pathOrMessage

			if not magick or not fontPath then
				if not errorShown then
					errorShown = true
					LrDialogs.showError(
						'EXIF Stamp: не найден ImageMagick (brew install imagemagick) '
						.. 'или системный шрифт. Фото экспортированы без надписи.' )
				end
			elseif isSupportedFile( filePath ) then
				local text = buildStampText( sourceRendition.photo, settings )
				if text ~= '' then
					stampPhoto( magick, fontPath, filePath, text, settings )
				else
					logger:trace( 'no EXIF data for ' .. filePath .. ', skipped' )
				end
			else
				logger:trace( 'unsupported file type, skipped: ' .. filePath )
			end
		else
			logger:error( 'render failed: ' .. tostring( pathOrMessage ) )
		end
	end
end

return ExifStampFilter
