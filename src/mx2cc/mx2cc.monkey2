
Namespace mx2cc

Using mx2.docs

#Import "<hoedown>"
#Import "<std>"

#Import "mx2.monkey2"

#Import "docs/docsmaker.monkey2"
#Import "docs/jsonbuffer.monkey2"
#Import "docs/markdownbuffer.monkey2"
#Import "docs/manpage.monkey2"

Using libc..
Using std..
Using mx2..

Global StartDir:String

Const TestArgs:="mx2cc makedocs mojox"

'Const TestArgs:="mx2cc makemods -clean std"' -target=android"

'Const TestArgs:="mx2cc makeapp -clean src/mx2cc/test.monkey2"

'Const TestArgs:="mx2cc makeapp src/ted2/ted2.monkey2"

'Const TestArgs:="mx2cc makemods -clean -config=release monkey libc miniz stb-image hoedown std"

'Const TestArgs:="mx2cc makeapp -verbose -target=desktop -config=release src/mx2cc/mx2cc.monkey2"

Function Main()

	Print "mx2cc version "+MX2CC_VERSION

	StartDir=CurrentDir()

	ChangeDir( AppDir() )
		
	Local env:="bin/env_"+HostOS+".txt"
	
	While Not IsRootDir( CurrentDir() ) And GetFileType( env )<>FILETYPE_FILE
	
		ChangeDir( ExtractDir( CurrentDir() ) )
	Wend
	
	If GetFileType( env )<>FILETYPE_FILE Fail( "Unable to locate mx2cc 'bin' directory" )
	
	LoadEnv( env )
	
	Local args:=AppArgs()
	
	If args.Length<2

		Print "Usage: mx2cc makeapp|makemods|makedocs [-build|-run] [-clean] [-verbose[=1|2|3]] [-target=desktop|emscripten] [-config=debug|release] [-apptype=gui|console] source|modules..."
		Print "Defaults: -run -target=desktop -config=debug -apptype=gui"

#If __CONFIG__="release"
		exit_(0)
#Endif
		args=TestArgs.Split( " " )
		
	Endif
	
	Local ok:=False
	
	Try
	
		Local cmd:=args[1]
		args=args.Slice( 2 )
		
		Select cmd
		Case "makeapp"
			ok=MakeApp( args )
		Case "makemods"
			ok=MakeMods( args )
		Case "makedocs"
			ok=MakeDocs( args )
		Default
			Fail( "Unrecognized mx2cc command: '"+cmd+"'" )
		End
		
	Catch ex:BuildEx
	
		Fail( "Internal mx2cc build error" )
		
	End
	
	If Not ok libc.exit_( 1 )
End

Function MakeApp:Bool( args:String[] )

	Local opts:=New BuildOpts
	opts.productType="app"
	opts.appType="gui"
	opts.target="desktop"
	opts.config="debug"
	opts.clean=False
	opts.fast=True
	opts.run=true
	opts.verbose=0
	
	args=ParseOpts( opts,args )
	
	If args.Length<>1 Fail( "Invalid app source file" )
	
	Local cd:=CurrentDir()
	ChangeDir( StartDir )
	Local srcPath:=RealPath( args[0].Replace( "\","/" ) )
	ChangeDir( cd )
	
	opts.mainSource=srcPath
	
	Print ""
	Print "***** Building app '"+opts.mainSource+"' *****"
	Print ""

	Local builder:=New Builder( opts )
	
	builder.Parse()
	If builder.errors.Length Return False
	
	builder.Semant()
	If builder.errors.Length Return False
	
	builder.Translate()
	If builder.errors.Length Return False

	builder.Compile()
	If builder.errors.Length Return False

	Local app:=builder.Link()
	If builder.errors.Length Return False
	
	If Not opts.run Print "Application built:"+app
	
	Return True
End

Function MakeMods:Bool( args:String[] )

	Local opts:=New BuildOpts
	opts.productType="module"
	opts.target="desktop"
	opts.config="debug"
	opts.clean=False
	opts.fast=True
	opts.verbose=0
	
	args=ParseOpts( opts,args )

	If Not args args=EnumModules()
	
	Local errs:=0
	
	For Local modid:=Eachin args
	
		Local path:="modules/"+modid+"/"+modid+".monkey2"
		If GetFileType( path )<>FILETYPE_FILE Fail( "Module file '"+path+"' not found" )
	
		Print ""
		Print "***** Making module '"+modid+"' *****"
		Print ""
		
		opts.mainSource=RealPath( path )
		
		Local builder:=New Builder( opts )
		
		builder.Parse()
		If builder.errors.Length errs+=1;Continue

		builder.Semant()
		If builder.errors.Length errs+=1;Continue
		
		builder.Translate()
		If builder.errors.Length errs+=1;Continue
		
		builder.Compile()
		If builder.errors.Length errs+=1;Continue

		builder.Link()
		If builder.errors.Length errs+=1
	Next
	
	Return errs=0
End

Function MakeDocs:Bool( args:String[] )

	Local opts:=New BuildOpts
	opts.productType="module"
	opts.target="desktop"
	opts.config="debug"
	opts.clean=False
	opts.fast=True
	opts.verbose=0
	
	args=ParseOpts( opts,args )
	opts.clean=False
	
	If Not args args=EnumModules()
	
	Local docsMaker:=New DocsMaker
	
	Local errs:=0
	
	For Local modid:=Eachin args

		Local path:="modules/"+modid+"/"+modid+".monkey2"
		If GetFileType( path )<>FILETYPE_FILE Fail( "Module file '"+path+"' not found" )
	
		Print ""
		Print "***** Doccing module '"+modid+"' *****"
		Print ""
		
		opts.mainSource=RealPath( path )
		
		Local builder:=New Builder( opts )

		builder.Parse()
		If builder.errors.Length errs+=1;Continue
		
		builder.Semant()
		If builder.errors.Length errs+=1;Continue
		
		docsMaker.MakeDocs( builder.modules.Top )
	Next
	
	Local api_indices:=New StringStack
	Local man_indices:=New StringStack
	
	For Local modid:=Eachin EnumModules()
	
		Local index:=LoadString( "modules/"+modid+"/docs/__MANPAGES__/index.js" )
		If index man_indices.Push( index )
		
		index=LoadString( "modules/"+modid+"/docs/__PAGES__/index.js" )
		If index api_indices.Push( index )
		
	Next
	
	Local page:=LoadString( "docs/modules_template.html" )
	page=page.Replace( "${API_INDEX}",api_indices.Join( "," ) )
	SaveString( page,"docs/modules.html" )
	
	page=LoadString( "docs/manuals_template.html" )
	page=page.Replace( "${MAN_INDEX}",man_indices.Join( "," ) )
	SaveString( page,"docs/manuals.html" )
	
	Return True
End

Function ParseOpts:String[]( opts:BuildOpts,args:String[] )

	opts.verbose=Int( GetEnv( "MX2_VERBOSE" ) )

	For Local i:=0 Until args.Length
	
		Local arg:=args[i]
	
		Local j:=arg.Find( "=" )
		If j=-1 
			Select arg
			Case "-run"
				opts.run=True
			Case "-build"
				opts.run=False
			Case "-clean"
				opts.clean=True
			Case "-verbose"
				opts.verbose=1
			Default
				Return args.Slice( i )
			End
			Continue
		Endif
		
		Local opt:=arg.Slice( 0,j ),val:=arg.Slice( j+1 ).ToLower()
		
		Select opt
		Case "-apptype"
			Select val
			Case "gui","console"
				opts.appType=val
			Default
				Fail( "Invalid value for 'apptype' option: '"+val+"' - must be 'gui' or 'console'" )
			End
		Case "-target"
			Select val
			Case "desktop","emscripten","android","ios"
				opts.target=val
			Default
				Fail( "Invalid value for 'target' option: '"+val+"' - must be 'desktop', 'emscripten', 'android' or 'ios'" )
			End
		Case "-config"
			Select val
			Case "debug","release"
				opts.config=val
			Default
				Fail( "Invalid value for 'config' option: '"+val+"' - must be 'debug' or 'release'" )
			End
		Case "-verbose"
			Select val
			Case "0","1","2","3","-1"
				opts.verbose=Int( val )
			Default
				Fail( "Invalid value for 'verbose' option: '"+val+"' - must be '0', '1', '2', '3' or '-1'" )
			End
		Default
			Fail( "Invalid option: '"+opt+"'" )
		End
	
	Next
	
	Return Null
End

Function EnumModules( out:StringStack,cur:String,deps:StringMap<StringStack> )
	If out.Contains( cur ) Return
	
	For Local dep:=Eachin deps[cur]
		EnumModules( out,dep,deps )
	Next
	
	out.Push( cur )
End

Function EnumModules:String[]()

	Local mods:=New StringMap<StringStack>

	For Local f:=Eachin LoadDir( "modules" )
	
		Local dir:="modules/"+f+"/"
		If GetFileType( dir )<>FileType.Directory Continue
		
		Local str:=LoadString( dir+"module.json" )
		If Not str Continue
		
		Local obj:=JsonObject.Parse( str )
		If Not obj 
			Print "Error parsing json:"+dir+"module.json"
			Continue
		Endif
		
		Local name:=obj["module"].ToString()
		If name<>f Continue
		
		Local deps:=New StringStack
		If name<>"monkey" deps.Push( "monkey" )
		
		Local jdeps:=obj["depends"]
		If jdeps
			For Local dep:=Eachin jdeps.ToArray()
				deps.Push( dep.ToString() )
			Next
		Endif
		
		mods[name]=deps
	Next
	
	Local out:=New StringStack
	For Local cur:=Eachin mods.Keys
		EnumModules( out,cur,mods )
	Next
	
	Return out.ToArray()
End

Function LoadEnv:Bool( path:String )

	SetEnv( "MX2_HOME",CurrentDir() )

	Local lineid:=0
	
	For Local line:=Eachin stringio.LoadString( path ).Split( "~n" )
		lineid+=1
	
		Local i:=line.Find( "'" )
		If i<>-1 line=line.Slice( 0,i )
		
		line=line.Trim()
		If Not line Continue
		
		i=line.Find( "=" )
		If i=-1 Fail( "Env config file error at line "+lineid )
		
		Local name:=line.Slice( 0,i ).Trim()
		Local value:=line.Slice( i+1 ).Trim()
		
		value=ReplaceEnv( value,lineid )
		
		SetEnv( name,value )

	Next
	
	Return True
End

Function ReplaceEnv:String( str:String,lineid:Int )
	Local i0:=0
	Repeat
		Local i1:=str.Find( "${",i0 )
		If i1=-1 Return str
		
		Local i2:=str.Find( "}",i1+2 )
		If i2=-1 Fail( "Env config file error at line "+lineid )
		
		Local name:=str.Slice( i1+2,i2 ).Trim()
		Local value:=GetEnv( name )
		
		str=str.Slice( 0,i1 )+value+str.Slice( i2+1 )
		i0=i1+value.Length
	Forever
	Return ""
End

Function Fail( msg:String )

	Print ""
	Print "***** Fatal mx2cc error *****"
	Print ""
	Print msg
		
	exit_( 1 )
End
