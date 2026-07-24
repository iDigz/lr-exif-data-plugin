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

local ROMAN_VERSIONS = { ['2'] = 'II', ['3'] = 'III', ['4'] = 'IV', ['5'] = 'V' }

-- Shorten camera model for display: "Canon EOS R5m2" -> "Canon R5 M II".
local function prettyCamera( model )
	if not model then return nil end
	local name = string.gsub( model, 'EOS%s*', '' )
	name = string.gsub( name, '(%w+)[mM](%d)$', function( base, version )
		return base .. ' M ' .. ( ROMAN_VERSIONS[ version ] or version )
	end )
	return trim( name )
end

-- Shorten lens name: keep everything up to the focal range and drop "mm":
-- "Canon RF 100-500mm F4.5-7.1L IS USM" -> "Canon RF 100-500".
-- A lens without a focal/aperture token is returned as-is.
local function prettyLens( lens )
	if not lens then return nil end
	local words = {}
	for rawWord in string.gmatch( lens, '%S+' ) do
		local focal = string.match( rawWord, '^(%d+%-?%d*)mm$' )
		if focal then
			words[ #words + 1 ] = focal
			break
		end
		-- Aperture token ("F2.8L", "f/2.8") — everything from here on is noise.
		if string.match( rawWord, '^[Ff]/?%d' ) then
			break
		end
		words[ #words + 1 ] = rawWord
	end
	return table.concat( words, ' ' )
end

-- Rows of the stamp block: left badge label + right value.
local function buildStampRows( meta, settings )
	local rows = {}

	local function add( enabled, label, value )
		if enabled and value then
			rows[ #rows + 1 ] = { label = label, value = string.upper( value ) }
		end
	end

	add( settings.exifstamp_showCamera, 'CAM', prettyCamera( meta.camera ) )
	add( settings.exifstamp_showLens, 'LENS', prettyLens( meta.lens ) )
	add( settings.exifstamp_showFocal, 'FOCAL',
		meta.focal and string.gsub( meta.focal, '%.0$', '' ) .. 'mm' or nil )
	add( settings.exifstamp_showAperture, 'APERTURE', meta.aperture and 'f/' .. meta.aperture or nil )
	add( settings.exifstamp_showShutter, 'SHUTTER', meta.shutter and meta.shutter .. 's' or nil )
	add( settings.exifstamp_showIso, 'ISO', meta.iso )

	return rows
end

-- Wrap text in single quotes for /bin/sh: ' becomes '\''
local function shellQuote( text )
	return "'" .. string.gsub( text, "'", "'\\''" ) .. "'"
end

-- Build the ImageMagick clause that renders the whole stamp block as one image
-- with transparency: a left column of badges (filled rectangles with knockout
-- letters showing the photo through) and a right column of values, right-aligned.
-- rh/sp/gap/sw/bp/bh are strings: either plain numbers (preview) or shell
-- variables like "$P" (export, where sizes depend on the image height measured
-- in shell). bp is the horizontal padding inside a badge, bh the badge box
-- height (smaller than the row height rh; the badge is padded back to rh with
-- transparent margins so both columns keep identical row heights).
-- fitW/fitH limit the final block size: it is shrunk (never enlarged) to fit,
-- so long lines in wide fonts do not get clipped at the image border.
local function buildBlockClause( rows, fontPath, settings, rh, sp, gap, sw, bp, bh, fitW, fitH )
	local badgeColor, fillColor, strokeColor
	if settings.exifstamp_color == 'black' then
		badgeColor, fillColor, strokeColor = 'black', 'black', 'white'
	else
		badgeColor, fillColor, strokeColor = 'white', 'white', 'black'
	end

	-- Parentheses are escaped as \( \) because the command runs through /bin/sh.
	local badges, values = {}, {}
	local spacer = string.format( '\\( -size 1x%s xc:none \\)', sp )

	for i, row in ipairs( rows ) do
		if i > 1 then
			badges[ #badges + 1 ] = spacer
			values[ #values + 1 ] = spacer
		end

		-- Badge: render the label, trim to the glyphs, center it inside the
		-- badge box via -extent, then negate + alpha-copy so the letters become
		-- transparent holes and paint the box. Finally pad the badge back to
		-- the full row height with transparent margins.
		-- The stroke thickens the glyphs (faux bold) — works with any font,
		-- unlike selecting a real bold face inside a .ttc file.
		badges[ #badges + 1 ] = string.format(
			'\\( -background black -fill white -stroke white -strokewidth %s '
			.. '-font "%s" -size x%s label:%s '
			.. '-trim +repage -gravity center -extent "%%[fx:w+%s*2]x%s" '
			.. '-negate -alpha copy -fill %s -colorize 100 '
			.. '-background none -extent "%%[fx:w]x%s" \\)',
			sw, fontPath, rh, shellQuote( row.label ), bp, bh, badgeColor, rh )

		-- Value: outline pass + clean fill pass on top.
		local quotedValue = shellQuote( row.value )
		values[ #values + 1 ] = string.format(
			'\\( \\( -background none -fill %s -stroke %s -strokewidth %s -font "%s" -size x%s label:%s \\) '
			.. '\\( -background none -fill %s -stroke none -font "%s" -size x%s label:%s \\) '
			.. '-background none -gravity center -compose over -composite \\)',
			fillColor, strokeColor, sw, fontPath, rh, quotedValue,
			fillColor, fontPath, rh, quotedValue )
	end

	return string.format(
		'\\( \\( %s -background none -gravity West -append \\) '
		.. '\\( %s -background none -gravity East -append \\) '
		.. '-background none +smush %s -resize "%sx%s>" \\)',
		table.concat( badges, ' ' ), table.concat( values, ' ' ), gap, fitW, fitH )
end

local function stampPhoto( magick, fontPath, filePath, rows, settings )
	local size = tonumber( settings.exifstamp_fontSize ) or 9
	local gravity = settings.exifstamp_corner or 'SouthEast'
	local quotedPath = '"' .. filePath .. '"'

	-- Sizes are derived from the image height in shell: P is the row height,
	-- S the outline width, SP the spacing between rows, GAP the gap between
	-- the columns (about one space character), BP the badge padding.
	-- MW/MH cap the block size so it never sticks out of the image.
	local blockClause = buildBlockClause( rows, fontPath, settings,
		'$P', '$SP', '$GAP', '$S', '$BP', '$BH', '$MW', '$MH' )

	local command = string.format(
		'WH=$(%s identify -format "%%w %%h" %s); W=${WH%%%% *}; H=${WH##* }; '
		.. 'P=$((H*%d/1000)); [ "$P" -lt 8 ] && P=8; '
		.. 'S=$((P/14+1)); SP=$((P/12)); GAP=$((P/2)); BP=$((P/8+1)); BH=$((P*4/5)); '
		.. 'MW=$((W-P*2)); MH=$((H-P*2)); '
		.. '%s %s %s -gravity %s -geometry "+$P+$P" -compose over -composite %s',
		magick, quotedPath, size,
		magick, quotedPath, blockClause, gravity, quotedPath
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
-- showing a cached image. Files live inside the plugin folder because
-- f:picture documents its value as "file or resource name from the plug-in".
local previewCounter = 0

-- Reference to the f:picture view of the currently open dialog. f:picture is
-- not documented as bindable, so besides the property binding we also assign
-- the new path straight to the view object (wrapped in pcall).
local previewPictureView = nil

-- Draw the EXIF block with sample data onto a small gradient swatch and point
-- the dialog picture at the result. Runs only in the export dialog, so any
-- failure here never affects the actual export. The point size is bigger than
-- the real ‰-of-height value so the text stays readable on the small swatch.
-- With openAfter = true the result is also opened in Preview.app.
local function generatePreview( propertyTable, openAfter )
	local magick = findExistingFile( MAGICK_CANDIDATES )
	if not magick then
		return
	end
	local settings = propertyTable

	LrTasks.startAsyncTask( function()
		local rows = buildStampRows( SAMPLE_META, settings )

		local rowHeight = ( tonumber( settings.exifstamp_fontSize ) or 9 ) + 8
		local gravity = settings.exifstamp_corner or 'SouthEast'
		local fontPath = resolveFont( settings )

		previewCounter = previewCounter + 1
		local outPath = LrPathUtils.child( _PLUGIN.path,
			'exifstamp_preview_' .. previewCounter .. '.jpg' )

		local blockClause = ''
		if #rows > 0 then
			blockClause = buildBlockClause( rows, fontPath, settings,
				tostring( rowHeight ), tostring( math.floor( rowHeight / 12 ) ),
				tostring( math.floor( rowHeight / 2 ) ), '2',
				tostring( math.floor( rowHeight / 8 ) + 1 ),
				tostring( math.floor( rowHeight * 4 / 5 ) ), '348', '228' )
				.. string.format( ' -gravity %s -geometry +16+16 -compose over -composite', gravity )
		end

		local command = string.format(
			'%s -size 380x260 gradient:gray25-gray70 %s "%s"',
			magick, blockClause, outPath )

		logger:trace( 'preview exec: ' .. command )
		local exitCode = LrTasks.execute( command )
		if exitCode ~= 0 then
			logger:error( 'preview magick failed with code ' .. tostring( exitCode ) )
			return
		end

		-- Update through the binding and directly on the view object; either
		-- mechanism may be the one that actually refreshes the picture.
		settings.exifstamp_previewPath = outPath
		if previewPictureView then
			pcall( function() previewPictureView.value = outPath end )
		end

		-- Drop the previous preview file so the plugin folder does not grow.
		local previousPath = LrPathUtils.child( _PLUGIN.path,
			'exifstamp_preview_' .. ( previewCounter - 1 ) .. '.jpg' )
		LrFileUtils.delete( previousPath )

		if openAfter then
			LrTasks.execute( 'open "' .. outPath .. '"' )
		end
	end )
end

function ExifStampFilter.sectionForFilterInDialog( f, propertyTable )
	-- Start with the static sample shipped inside the plugin so the picture is
	-- never empty, then let generatePreview replace it with the styled one.
	propertyTable.exifstamp_previewPath = LrPathUtils.child( _PLUGIN.path, 'sample-preview.jpg' )

	-- The view is recreated on every dialog open; keep the fresh reference.
	previewPictureView = f:picture {
		value = bind 'exifstamp_previewPath',
		frame_width = 1,
	}

	-- Set up preview regeneration once per property table.
	if not propertyTable._exifstampReady then
		propertyTable._exifstampReady = true

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
	end

	generatePreview( propertyTable )

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
			previewPictureView,
			f:push_button {
				title = 'Открыть пример',
				action = function()
					generatePreview( propertyTable, true )
				end,
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
				local rows = meta and buildStampRows( meta, settings ) or {}
				if #rows > 0 then
					stampPhoto( magick, resolveFont( settings ), filePath, rows, settings )
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

-- Internal functions exposed for testing outside Lightroom (see tests/).
ExifStampFilter._test = {
	prettyCamera = prettyCamera,
	prettyLens = prettyLens,
	buildStampRows = buildStampRows,
	buildBlockClause = buildBlockClause,
}

return ExifStampFilter
