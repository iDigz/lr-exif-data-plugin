-- Renders the stamp block outside Lightroom using the plugin's own code.
-- Usage: lua tests/render_sim.lua <out.jpg> [corner] [color]

local outPath = arg[1] or 'sim_out.jpg'
local corner = arg[2] or 'SouthWest'
local color = arg[3] or 'white'

-- Stub the Lightroom runtime so ExifStampFilter.lua can be loaded as-is.
_PLUGIN = { path = '.' }
local stubs = {
	LrView = { bind = function( k ) return k end, share = function( k ) return k end },
	LrTasks = {},
	LrFileUtils = { exists = function() return true end },
	LrPathUtils = {},
	LrDialogs = {},
	-- LrLogger is used as: LrLogger('ExifStamp'):enable('logfile')
	LrLogger = function()
		return { enable = function() end, trace = function() end, error = function() end }
	end,
}
function import( name )
	return stubs[ name ]
end

local filter = dofile( 'ExifStamp.lrplugin/ExifStampFilter.lua' )
local t = filter._test

-- Parser checks
local checks = {
	{ t.prettyCamera( 'Canon EOS R5m2' ), 'Canon R5 M II' },
	{ t.prettyCamera( 'Canon EOS R6m3' ), 'Canon R6 M III' },
	{ t.prettyCamera( 'Canon EOS R5' ), 'Canon R5' },
	{ t.prettyLens( 'Canon RF 24-70mm F2.8L IS USM' ), 'Canon RF 24-70 F2.8L' },
	{ t.prettyLens( 'Canon RF 100-500mm F4.5-7.1L IS USM' ), 'Canon RF 100-500 F4.5-7.1L' },
	{ t.prettyLens( 'FE 35mm F1.8' ), 'FE 35 F1.8' },
}
for i, c in ipairs( checks ) do
	if c[1] ~= c[2] then
		print( string.format( 'PARSER FAIL #%d: got %q want %q', i, tostring( c[1] ), c[2] ) )
		os.exit( 1 )
	end
end
print( 'parsers OK' )

-- Render the block with the plugin's own clause builder
local meta = { camera = 'Canon EOS R5m2', lens = 'Canon RF 24-70mm F2.8L IS USM',
	focal = '50', aperture = '2.8', shutter = '1/250', iso = '8000' }
local settings = { exifstamp_color = color,
	exifstamp_showCamera = true, exifstamp_showLens = true, exifstamp_showFocal = true,
	exifstamp_showAperture = true, exifstamp_showShutter = true, exifstamp_showIso = true }

local rows = t.buildStampRows( meta, settings )
local fontPath = arg[4] or '/System/Library/Fonts/Helvetica.ttc'
local clause = t.buildBlockClause( rows, fontPath, settings,
	'17', '3', '8', '2', '3', '14', '348', '228' )
local cmd = string.format(
	'/opt/homebrew/bin/magick -size 380x260 gradient:gray25-gray70 %s '
	.. '-gravity %s -geometry +16+16 -compose over -composite "%s"',
	clause, corner, outPath )
print( cmd )
os.exit( os.execute( cmd ) and 0 or 1 )
