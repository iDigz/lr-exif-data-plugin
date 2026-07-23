-- Export filter: stamps EXIF info (camera, lens, exposure) onto exported photos
-- using ImageMagick. The rendered file is modified in place after Lightroom
-- finishes rendering it.
--
-- Camera and lens names come from exiftool run on the ORIGINAL file, not from
-- Lightroom's metadata. Lightroom only exposes the short lens name
-- ("RF24-70mm F2.8 L IS USM"); exiftool's LensID gives the full, properly
-- spaced name ("Canon RF 24-70mm F2.8L IS USM").

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

local EXIFTOOL_CANDIDATES = {
	'/opt/homebrew/bin/exiftool',
	'/usr/local/bin/exiftool',
}

local FONT_CANDIDATES = {
	'/System/Library/Fonts/Helvetica.ttc',
	'/System/Library/Fonts/Monaco.ttf',
}

local DEFAULT_FONT = '/System/Library/Fonts/Helvetica.ttc'

-- Curated list of good caption fonts. Only the ones present on the machine are
-- shown in the dialog. Order here is the order in the popup menu.
local FONT_CHOICES = {
	{ title = 'Helvetica', path = '/System/Library/Fonts/Helvetica.ttc' },
	{ title = 'Helvetica Neue', path = '/System/Library/Fonts/HelveticaNeue.ttc' },
	{ title = 'San Francisco', path = '/System/Library/Fonts/SFNS.ttf' },
	{ title = 'SF Mono', path = '/System/Library/Fonts/SFNSMono.ttf' },
	{ title = 'Avenir', path = '/System/Library/Fonts/Avenir.ttc' },
	{ title = 'Avenir Next', path = '/System/Library/Fonts/Avenir Next.ttc' },
	{ title = 'Arial', path = '/System/Library/Fonts/ArialHB.ttc' },
	{ title = 'Futura', path = '/System/Library/Fonts/Supplemental/Futura.ttc' },
	{ title = 'Gill Sans', path = '/System/Library/Fonts/Supplemental/GillSans.ttc' },
	{ title = 'Optima', path = '/System/Library/Fonts/Optima.ttc' },
	{ title = 'Menlo', path = '/System/Library/Fonts/Menlo.ttc' },
	{ title = 'Monaco', path = '/System/Library/Fonts/Monaco.ttf' },
	{ title = 'Courier', path = '/System/Library/Fonts/Courier.ttc' },
	{ title = 'Georgia', path = '/System/Library/Fonts/Supplemental/Georgia.ttf' },
	{ title = 'Times New Roman', path = '/System/Library/Fonts/Supplemental/Times New Roman.ttf' },
	{ title = 'Palatino', path = '/System/Library/Fonts/Palatino.ttc' },
	{ title = 'Baskerville', path = '/System/Library/Fonts/Supplemental/Baskerville.ttc' },
}

local SUPPORTED_EXTENSIONS = { jpg = true, jpeg = true, png = true, tif = true, tiff = true }

local ExifStampFilter = {}

ExifStampFilter.exportPresetFields = {
	{ key = 'exifstamp_enabled', default = true },
	{ key = 'exifstamp_corner', default = 'SouthEast' },
	{ key = 'exifstamp_fontSize', default = 9 },     -- text height, 1/1000 of image height
	{ key = 'exifstamp_font', default = DEFAULT_FONT },
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

-- Popup items for every curated font that exists on this machine.
local function buildFontItems()
	local items = {}
	for _, font in ipairs( FONT_CHOICES ) do
		if LrFileUtils.exists( font.path ) then
			items[ #items + 1 ] = { title = font.title, value = font.path }
		end
	end
	return items
end

-- The font chosen in the dialog, or a safe fallback if it is missing.
local function resolveFont( settings )
	local path = settings.exifstamp_font
	if path and LrFileUtils.exists( path ) then
		return path
	end
	return findExistingFile( FONT_CANDIDATES )
end

local function trim( value )
	return ( string.gsub( value, '^%s*(.-)%s*$', '%1' ) )
end

-- Split text into a list of lines, ignoring carriage returns.
local function splitLines( text )
	local lines = {}
	text = string.gsub( text, '\r', '' )
	for line in string.gmatch( text .. '\n', '([^\n]*)\n' ) do
		lines[ #lines + 1 ] = trim( line )
	end
	return lines
end

-- exiftool prints "-" (because of the -f flag) for any tag it cannot find.
local function tagOrNil( value )
	if not value or value == '' or value == '-' then
		return nil
	end
	return value
end

-- Read camera/lens/exposure from the original file with a single exiftool call.
-- Output is captured by redirecting to a temp file, then read back.
-- The tag order here MUST match the parsing below.
local function readMetadata( exiftool, sourcePath, tempDir )
	local outPath = LrPathUtils.child( tempDir,
		'exifstamp_' .. LrPathUtils.leafName( sourcePath ) .. '.txt' )

	local command = string.format(
		'"%s" -s3 -f -Model -LensID -LensModel -FocalLength# -FNumber -ExposureTime -ISO "%s" > "%s" 2>/dev/null',
		exiftool, sourcePath, outPath )

	logger:trace( 'exec: ' .. command )
	local exitCode = LrTasks.execute( command )
	if exitCode ~= 0 then
		logger:error( 'exiftool failed with code ' .. tostring( exitCode ) .. ' for ' .. sourcePath )
		return nil
	end

	local content = LrFileUtils.readFile( outPath )
	LrFileUtils.delete( outPath )
	if not content then
		return nil
	end

	local lines = splitLines( content )
	local lensID = tagOrNil( lines[ 2 ] )
	local lensModel = tagOrNil( lines[ 3 ] )

	-- LensID is the full name, but sometimes exiftool cannot decide and returns
	-- "X or Y" — fall back to the short LensModel in that case.
	local lens = lensModel
	if lensID and not string.find( lensID, ' or ' ) then
		lens = lensID
	end

	return {
		camera = tagOrNil( lines[ 1 ] ),
		lens = lens,
		focal = tagOrNil( lines[ 4 ] ),
		aperture = tagOrNil( lines[ 5 ] ),
		shutter = tagOrNil( lines[ 6 ] ),
		iso = tagOrNil( lines[ 7 ] ),
	}
end

-- Turn raw exiftool values into compact display strings.
local function formatFocal( value )
	if not value then return nil end
	value = string.gsub( value, '%.0$', '' )   -- "50.0" -> "50"
	return value .. 'mm'
end

local function formatAperture( value )
	if not value then return nil end
	return 'f/' .. value
end

local function formatShutter( value )
	if not value then return nil end
	return value .. 's'
end

local function formatIso( value )
	if not value then return nil end
	return 'ISO ' .. value
end

local function buildStampText( meta, settings )
	local parts = {}

	local function add( enabled, value )
		if enabled and value then
			parts[ #parts + 1 ] = value
		end
	end

	add( settings.exifstamp_showCamera, meta.camera )
	add( settings.exifstamp_showLens, meta.lens )
	add( settings.exifstamp_showFocal, formatFocal( meta.focal ) )
	add( settings.exifstamp_showAperture, formatAperture( meta.aperture ) )
	add( settings.exifstamp_showShutter, formatShutter( meta.shutter ) )
	add( settings.exifstamp_showIso, formatIso( meta.iso ) )

	-- Join with a literal "\n" sequence: ImageMagick's -annotate interprets it
	-- as a line break, so each item ends up on its own line.
	return table.concat( parts, '\\n' )
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

	local size = tonumber( settings.exifstamp_fontSize ) or 9
	local gravity = settings.exifstamp_corner or 'SouthEast'
	local quotedPath = '"' .. filePath .. '"'
	local quotedText = shellQuote( text )

	-- One shell line: measure image height, derive point size, padding and
	-- stroke width, then draw the text twice (outline pass + fill pass).
	local command = string.format(
		'H=$(%s identify -format %%h %s); P=$((H*%d/1000)); [ "$P" -lt 8 ] && P=8; S=$((P/14+1)); '
		.. '%s %s -gravity %s -font "%s" -pointsize "$P" -interline-spacing "$((P/3))" '
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

-- Sample EXIF used only for the dialog preview, so the user sees the styling
-- (font, size, color, corner, which lines) without needing a real photo.
local SAMPLE_META = {
	camera = 'Canon EOS R5m2',
	lens = 'Canon RF 24-70mm F2.8L IS USM',
	focal = '50',
	aperture = '2.8',
	shutter = '1/250',
	iso = '8000',
}

-- Each preview goes to a new file so the dialog's picture reloads instead of
-- showing a cached image.
local previewCounter = 0

-- Draw the EXIF block with sample data onto a small gradient swatch and point
-- the dialog picture at the result. Runs only in the export dialog, so any
-- failure here never affects the actual export. The point size is bigger than
-- the real ‰-of-height value so the text stays readable on the small swatch.
local function generatePreview( propertyTable )
	local magick = findExistingFile( MAGICK_CANDIDATES )
	if not magick then
		return
	end
	local settings = propertyTable

	LrTasks.startAsyncTask( function()
		local text = buildStampText( SAMPLE_META, settings )
		if text == '' then
			text = 'Нет выбранных полей'
		end

		local fillColor, strokeColor
		if settings.exifstamp_color == 'black' then
			fillColor, strokeColor = 'black', 'white'
		else
			fillColor, strokeColor = 'white', 'black'
		end

		local pointSize = ( tonumber( settings.exifstamp_fontSize ) or 9 ) + 8
		local gravity = settings.exifstamp_corner or 'SouthEast'
		local fontPath = resolveFont( settings )
		local quotedText = shellQuote( text )

		previewCounter = previewCounter + 1
		local outPath = LrPathUtils.child(
			LrPathUtils.getStandardFilePath( 'temp' ),
			'exifstamp_preview_' .. previewCounter .. '.jpg' )

		local command = string.format(
			'%s -size 380x260 gradient:gray25-gray70 -gravity %s -font "%s" -pointsize %d '
			.. '-interline-spacing %d -stroke %s -strokewidth 2 -fill %s -annotate +16+16 %s '
			.. '-stroke none -fill %s -annotate +16+16 %s "%s"',
			magick, gravity, fontPath, pointSize,
			math.floor( pointSize / 3 ), strokeColor, fillColor, quotedText,
			fillColor, quotedText, outPath )

		logger:trace( 'preview exec: ' .. command )
		local exitCode = LrTasks.execute( command )
		if exitCode == 0 then
			settings.exifstamp_previewPath = outPath
		else
			logger:error( 'preview magick failed with code ' .. tostring( exitCode ) )
		end
	end )
end

function ExifStampFilter.sectionForFilterInDialog( f, propertyTable )
	-- Set up the live preview once per dialog.
	if not propertyTable._exifstampReady then
		propertyTable._exifstampReady = true
		propertyTable.exifstamp_previewPath = ''

		local observedKeys = {
			'exifstamp_enabled', 'exifstamp_corner', 'exifstamp_fontSize',
			'exifstamp_font', 'exifstamp_color',
			'exifstamp_showCamera', 'exifstamp_showLens', 'exifstamp_showFocal',
			'exifstamp_showAperture', 'exifstamp_showShutter', 'exifstamp_showIso',
		}
		for _, key in ipairs( observedKeys ) do
			propertyTable:addObserver( key, function()
				generatePreview( propertyTable )
			end )
		end

		generatePreview( propertyTable )
	end

	return {
		title = 'EXIF Stamp',

		f:column {
			bind_to_object = propertyTable,
			spacing = f:control_spacing(),

			f:row {
				f:checkbox {
					title = 'Накладывать EXIF на фото',
					value = bind 'exifstamp_enabled',
				},
			},

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
					value = bind 'exifstamp_fontSize',
					items = {
						{ title = 'Мелкий', value = 6 },
						{ title = 'Средний', value = 9 },
						{ title = 'Крупный', value = 12 },
					},
				},
			},

			f:row {
				f:static_text { title = 'Шрифт:', width = LrView.share 'exifstamp_label' },
				f:popup_menu {
					value = bind 'exifstamp_font',
					items = buildFontItems(),
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

			f:spacer { height = 6 },

			f:static_text { title = 'Предпросмотр (пример данных):' },
			f:picture {
				value = bind 'exifstamp_previewPath',
				frame_width = 380,
				frame_height = 260,
			},
		},
	}
end

function ExifStampFilter.postProcessRenderedPhotos( functionContext, filterContext )
	local settings = filterContext.propertyTable

	-- Filter disabled: let every photo pass through untouched. We still have to
	-- wait for each rendition so the export pipeline can finish.
	if not settings.exifstamp_enabled then
		for sourceRendition in filterContext:renditions() do
			sourceRendition:waitForRender()
		end
		return
	end

	local magick = findExistingFile( MAGICK_CANDIDATES )
	local exiftool = findExistingFile( EXIFTOOL_CANDIDATES )
	local fontPath = findExistingFile( FONT_CANDIDATES )
	local tempDir = LrPathUtils.getStandardFilePath( 'temp' )
	local errorShown = false

	for sourceRendition, renditionToSatisfy in filterContext:renditions() do
		local success, pathOrMessage = sourceRendition:waitForRender()

		if success then
			local filePath = pathOrMessage

			if not magick or not exiftool or not fontPath then
				if not errorShown then
					errorShown = true
					LrDialogs.showError(
						'EXIF Stamp: не найдены ImageMagick и exiftool '
						.. '(brew install imagemagick exiftool) или системный шрифт. '
						.. 'Фото экспортированы без надписи.' )
				end
			elseif isSupportedFile( filePath ) then
				local sourcePath = sourceRendition.photo:getRawMetadata( 'path' )
				local meta = readMetadata( exiftool, sourcePath, tempDir )
				local text = meta and buildStampText( meta, settings ) or ''
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
