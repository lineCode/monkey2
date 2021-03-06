
Namespace mx2

'Really only for c++ translator right now, but splits out some grunt work from main translator!

'Does type need bbGCMark()ing?
'
Function IsGCType:Bool( type:Type )

	If type=Type.VariantType Return true
	
	If TCast<FuncType>( type ) Return True
	
	If TCast<ArrayType>( type ) Return True
	
	Local ctype:=TCast<ClassType>( type )
	If Not ctype Return False
	
	If ctype.ExtendsVoid Return False
	
	If ctype.cdecl.kind="class" Or ctype.cdecl.kind="interface" Return True
	
	If ctype.cdecl.kind="struct"
		For Local vvar:=Eachin ctype.fields
			If IsGCType( vvar.type ) Return True
		Next
		Return False
	Endif
	
	Return False
End

Function IsGCPtrType:Bool( type:Type )

	Local ctype:=TCast<ClassType>( type )
	
	Return ctype And Not ctype.ExtendsVoid And (ctype.IsClass Or ctype.IsInterface)
End

'Visitor that looks for gc params on LHS of an assignment.
'
Class AssignedGCParamsVisitor Extends StmtVisitor

	Field gcparams:=New StringMap<VarValue>
	
	Method Visit( stmt:AssignStmt ) Override
		Local vvar:=Cast<VarValue>( stmt.lhs )
		If vvar And vvar.vdecl.kind="param" And IsGCType( vvar.type ) gcparams[vvar.vdecl.ident]=vvar
	End

End

Class Translator

	Field _debug:Bool
	
	Method New()
		_debug=Builder.opts.config="debug"
	End
	
	Method Reset() Virtual
		_buf.Clear()
		_insertStack.Clear()
		_indent=""
		_gcframe=Null
		_deps=New Deps
	End
	
	Method Trans:String( value:Value ) Abstract
	
	Method TransType:String( type:Type ) Abstract

	Method VarProto:String( vvar:VarValue ) Abstract
	
	Method FuncProto:String( func:FuncValue ) Abstract

	'***** Emit *****
	
	Field _buf:=New StringStack
	Field _insertStack:=New Stack<StringStack>
	Field _indent:String
	
	Method EmitBr()
		If _buf.Length And Not _buf.Top Return
		_buf.Push( "" )
	End
	
	Method Emit( str:String )
	
		If Not str Return
	
		If str.StartsWith( "}" ) _indent=_indent.Slice( 0,-2 )

		_buf.Push( _indent+str )

		If str.EndsWith( "{" ) _indent+="  "
	End
	
	Property InsertPos:Int()
	
		Return _buf.Length
	End
	
	Method BeginInsert( pos:Int )
	
		Local buf:=_buf.Slice( pos )
	
		_insertStack.Push( buf )
		
		_buf.Resize( pos )
	End
	
	Method EndInsert()
	
		Local buf:=_insertStack.Pop()
		
		If _buf.Length And Not _buf.Top And buf.Length And Not buf[0] buf=buf.Slice( 1 )
		
		_buf.Append( buf )
	End
	
	'***** GCFrame *****
	
	Class GCTmp
		Field used:Bool
		Field type:Type
		Field ident:String
	End

	Class GCFrame
		Field outer:GCFrame
		Field inspos:Int
		Field depth:Int
		Field ident:String
		Field vars:=New StringMap<VarValue>
		Field tmps:=New Stack<GCTmp>
		
		Method New( outer:GCFrame,inspos:Int )
			Self.outer=outer
			Self.inspos=inspos
			If outer Self.depth=outer.depth+1
			ident="f"+depth
		End
	End
	
	Field _gcframe:GCFrame
	
	method ResetGC()
		_gcframe=Null
	End
	
	Method BeginGCFrame()
		_gcframe=New GCFrame( _gcframe,InsertPos )
	End
	
	Method BeginGCFrame( func:FuncValue )
	
		BeginGCFrame()
		
		Local visitor:=New AssignedGCParamsVisitor
		visitor.Visit( func.block )
		
		For Local it:=Eachin visitor.gcparams
			InsertGCTmp( it.Value )
		Next
		
	End
	
	Method EndGCFrame()
	
		If Not _gcframe.vars.Empty Or Not _gcframe.tmps.Empty
	
			BeginInsert( _gcframe.inspos )
			
			Emit( "struct "+_gcframe.ident+"_t : public bbGCFrame{" )
			
			Local ctorArgs:="",ctorInits:="",ctorVals:=""
			
			For Local varval:=Eachin _gcframe.vars.Values

				Local varty:=TransType( varval.type )
				Local varid:=VarName( varval )
				
				Emit( varty+" "+varid+"{};" )
				
				If varval.vdecl.kind="param"
					ctorArgs+=","+varty+" "+varid
					ctorInits+=","+varid+"("+varid+")"
					ctorVals+=","+varid
				Endif
				
			Next
			
			For Local tmp:=Eachin _gcframe.tmps
				
				Emit( TransType( tmp.type )+" "+tmp.ident+"{};" )
			Next
			
			If ctorArgs
				ctorVals="{"+ctorVals.Slice( 1 )+"}"
				Emit( _gcframe.ident+"_t("+ctorArgs.Slice( 1 )+"):"+ctorInits.Slice( 1 )+"{" )
				Emit( "}" )
			Else
				ctorVals="{}"
			Endif
			
			Emit( "void gcMark(){" )

			For Local vvar:=Eachin _gcframe.vars.Values

				Emit( "bbGCMark("+VarName( vvar )+");" )

				MarksType( vvar.type )
			Next
			
			For Local tmp:=Eachin _gcframe.tmps
			
				Emit( "bbGCMark("+tmp.ident+");" )
				
				MarksType( tmp.type )
			Next
			
			Emit( "}" )
			
			Emit( "}"+_gcframe.ident+ctorVals+";" )
	
			EndInsert()
			
		Endif
			
		_gcframe=_gcframe.outer
	End
	
	Method AllocGCTmp:String( type:Type )
	
		For Local i:=0 Until _gcframe.tmps.Length
			Local tmp:=_gcframe.tmps[i]
			If tmp.used Or Not tmp.type.Equals( type ) Continue
			tmp.used=True
			Return _gcframe.ident+"."+tmp.ident
		Next
		
		Local tmp:=New GCTmp
		tmp.used=True
		tmp.type=type
		tmp.ident="t"+_gcframe.tmps.Length
		_gcframe.tmps.Push( tmp )
		
		Return _gcframe.ident+"."+tmp.ident
	End
	
	Method FreeGCTmps()
		For Local i:=0 Until _gcframe.tmps.Length
			_gcframe.tmps[i].used=False
		Next
	End
	
	Method InsertGCTmp:String( vvar:VarValue )
		
		_gcframe.vars[vvar.vdecl.ident]=vvar
		Return _gcframe.ident+"."+VarName( vvar )
	End
	
	Method FindGCTmp:String( vvar:VarValue )

		Local vdecl:=vvar.vdecl
		Local frame:=_gcframe
		
		While frame
			If frame.vars[vdecl.ident]=vvar Return frame.ident+"."+VarName( vvar )
			frame=frame.outer
		Wend
		
		'should really be an unassigned param
		'		
		Return VarName( vvar )
	End
	
	'***** Dependancies *****

	Class Deps
		Field depsPos:Int

		Field included:=New Map<FileDecl,Bool>
		
		Field usesFiles:=New Map<FileDecl,Bool>
		Field includes:=New Stack<FileDecl>
		
		Field refs:=New Map<SNode,Bool>
		
		Field refsVars:=New Stack<VarValue>
		Field refsFuncs:=New Stack<FuncValue>
		Field refsTypes:=New Stack<Type>
	End
	
	Field _deps:Deps
	
	Method Included:Bool( fdecl:FileDecl )
	
		Return _deps.included[fdecl]
	End
	
	Method EmitInclude( fdecl:FileDecl,baseDir:String )
	
		If _deps.included[fdecl] Return

		Emit( "#include ~q"+MakeIncludePath( fdecl.hfile,baseDir )+"~q" )
		
		_deps.included[fdecl]=True
	End
	
	Method BeginDeps()
	
		_deps.depsPos=InsertPos
	End
	
	Method EndDeps( baseDir:String )
	
		BeginInsert( _deps.depsPos )

		'sort usesfiles	
		Local includes:=New Stack<FileDecl>( _deps.includes )
		includes.Sort( Lambda:Int( x:FileDecl,y:FileDecl )
			Return x.hfile<=>y.hfile
		End )
		_deps.includes.Clear()
		
		'Emit includes	
		EmitBr()
		For Local fdecl:=Eachin includes
			EmitInclude( fdecl,baseDir )
		Next
		
		'sort refsTypes
		Local refsTypes:=New Stack<Type>( _deps.refsTypes )
		refsTypes.Sort( Lambda:Int( x:Type,y:Type )
			Return x.Name<=>y.Name
		End )
		_deps.refsTypes.Clear()
		
		'Emit refsTypes
		EmitBr()
		For Local type:=Eachin refsTypes
		
			Local ctype:=TCast<ClassType>( type )
			If ctype
				If Included( ctype.transFile ) Continue
				
				Local cname:=ClassName( ctype )
				
				If ctype.IsStruct
					Emit( "BB_STRUCT("+cname+")" )
				Else
					Emit( "BB_CLASS("+cname+")" )
				Endif
				
				Continue
			Endif
			
			Local etype:=TCast<EnumType>( type )
			If etype
				If Included( etype.transFile ) Continue
				
				Local ename:=EnumName( etype )
				
				Emit( "BB_ENUM("+ename+")" )
				
				Continue
			Endif

		Next

		'sort refsVars		
		Local refsVars:=New Stack<VarValue>( _deps.refsVars )
		refsVars.Sort( Lambda:Int( x:VarValue,y:VarValue )
			Return x.Name<=>y.Name
		End )
		_deps.refsVars.Clear()
		
		'emit refsVars
		EmitBr()	
		For Local vvar:=Eachin refsVars
			If Not Included( vvar.transFile ) Emit( "extern "+VarProto( vvar )+";" )
		Next
		
		'sort refsFuncs
		Local refsFuncs:=New Stack<FuncValue>( _deps.refsFuncs )
		refsFuncs.Sort( Lambda:Int( x:FuncValue,y:FuncValue )
			Return x.Name<=>y.Name
		End )
		_deps.refsFuncs.Clear()
		
		'emit refsFuncs
		EmitBr()
		For Local func:=Eachin refsFuncs
			If Not Included( func.transFile ) Emit( "extern "+FuncProto( func )+";" )
		Next
		
		EndInsert()
		
		_deps.depsPos=InsertPos
	End
	
	#rem
Method AddRef:Bool( node:SNode )
		If _deps.refs[node] Return True
		_deps.refs[node]=True
		Return False
	End
	
	Method RefsVar( vvar:VarValue )
	
		If vvar.vdecl.IsExtern Uses( vvar.transFile ) ; Return
		
		If vvar.IsStatic
			If AddRef( vvar ) Return
			_deps.refsVars.Push( vvar )
		End
		
		Refs( vvar.type )
	End
	
	Method Refs( func:FuncValue )
	
		If func.fdecl.IsExtern Uses( func.transFile ) ; Return
		
		If func.IsStatic
			If AddRef( func ) Return
			_deps.refsFuncs.Push( func )
		Endif
		
		Refs( func.ftype )
	End
	
	Method Refs( type:Type )
	
		Local ctype:=TCast<ClassType>( type )
		If ctype
			If ctype.cdecl.IsExtern Uses( ctype.transFile ) ; Return
			If AddRef( ctype ) Return
			_deps.refsTypes.Push( ctype )
			Return
		Endif
		
		Local etype:=TCast<EnumType>( type )
		If etype
			If AddRef( etype ) Return
			_deps.refsTypes.Push( etype )
			Return
		Endif
		
		Local ftype:=TCast<FuncType>( type )
		If ftype
			Refs( ftype.retType )
			For Local type:=Eachin ftype.argTypes
				Refs( type )
			Next
			Return
		Endif
		
		Local atype:=TCast<ArrayType>( type )
		If atype
			Local ctype:=TCast<ClassType>( atype.elemType )
			If ctype And ctype.IsStruct
				Uses( ctype )
			Else
				Refs( atype.elemType )
			Endif
			Return
		Endif
		
		Local ptype:=TCast<PointerType>( type )
		If ptype
			Refs( ptype.elemType )
			Return
		Endif
		
	End
	
	Method Uses( type:Type )
		
		Local ctype:=TCast<ClassType>( type )
		If ctype
			_deps.uses[ctype]=True 
			Uses( ctype.transFile )
			Return
		Endif

		Refs( type )
	End
	
	Method Uses( fdecl:FileDecl )
		
		_deps.usesFiles[fdecl]=True
	End
	
	Method UsesRefInfo( type:Type )
	
		Local ctype:=TCast<ClassType>( type )
		If ctype
			Uses( ctype.transFile )
			Return
		Endif
		
		Local etype:=TCast<EnumType>( type )
		If etype
			Uses( etype.transFile )
			Return
		Endif
	
		Local ftype:=TCast<FuncType>( type )
		If ftype
			UsesRefInfo( ftype.retType )
			For Local type:=Eachin ftype.argTypes
				UsesRefInfo( type )
			Next
			Return
		Endif
		
		Local atype:=TCast<ArrayType>( type )
		If atype
			UsesRefInfo( atype.elemType )
			Return
		Endif
		
		Local ptype:=TCast<PointerType>( type )
		If ptype
			UsesRefInfo( ptype.elemType )
			Return
		Endif
		
		Uses( type )
	End
	
	Method UsesRefInfo( vvar:VarValue )
	
		UsesRefInfo( vvar.type )
	
		Uses( vvar.transFile )
	End
	
	Method UsesRefInfo( func:FuncValue )
	
		UsesRefInfo( func.type )
		
		Uses( func.transFile )
	End

	Method Marks( type:Type )
	
		Local ctype:=TCast<ClassType>( type )
		If ctype 
			Uses( ctype )
			Return
		Endif

		Local ftype:=TCast<FuncType>( type )
		If ftype
			Marks( ftype.retType )
			For Local type:=Eachin ftype.argTypes
				Marks( type )
			Next
			Return
		Endif

		Local atype:=TCast<ArrayType>( type )
		If atype
			Marks( atype.elemType )
			Return
		Endif
		
		Refs( type )
	End
			
	Method Decls( type:Type )
	
		Local ctype:=TCast<ClassType>( type )
		If ctype And ctype.IsStruct Uses( ctype ) ; Return
		
		Refs( type )
	End
	
	Method Decls( vvar:VarValue )
		Decls( vvar.type )
	End
	
	Method Decls( func:FuncValue )
		Decls( func.ftype.retType )
		For Local type:=Eachin func.ftype.argTypes
			Decls( type )
		Next
	End
	#end
	
	'***** New versions of these monstrosities! *****
	
	Method UsesFile( fdecl:FileDecl )
		If _deps.usesFiles[fdecl] Return
		_deps.usesFiles[fdecl]=True
		_deps.includes.Add( fdecl )
	End
	
	Method AddRef:Bool( node:SNode )
		If _deps.refs[node] Return False
		_deps.refs[node]=True
		Return True
	End
	
	Method RefsVar( vvar:VarValue )
	
		If vvar.vdecl.IsExtern 
			UsesFile( vvar.transFile )
			Return
		Endif
		
		If vvar.IsStatic
			If Not AddRef( vvar ) Return
			_deps.refsVars.Push( vvar )
		End
		
		RefsType( vvar.type )
	End
	
	Method RefsFunc( func:FuncValue )
	
		If func.fdecl.IsExtern UsesFile( func.transFile ) ; Return
		
		If func.IsStatic
			If Not AddRef( func ) Return
			_deps.refsFuncs.Push( func )
		Endif
		
		RefsType( func.ftype )
	End
	
	Method DeclsFunc( type:FuncType )
		
		DeclsVar( type.retType )
		For Local argty:=Eachin type.argTypes
			DeclsVar( argty )
		Next
	End
	
	Method DeclsVar( type:Type )
		
		Local ctype:=TCast<ClassType>( type )
		If ctype And ctype.IsStruct
			UsesType( ctype )
			Return
		Endif
		
		RefsType( type )
	End
	
	Method MarksType( type:Type )
		
		#rem don't need to do this as using an array uses element type anyway...
		Local atype:=TCast<ArrayType>( type )
		If atype
			'need to see full type of element type when marking an array of values.
			Local ctype:=TCast<ClassType>( atype.elemType )
			If ctype And ctype.IsStruct UsesType( ctype )
			Return
		Endif
		#end

		UsesType( type )
	End
	
	Method UsesType( type:Type )
		
		Local xtype:=Cast<AliasType>( type )
		If xtype
			If xtype.adecl.IsExtern UsesFile( xtype.transFile ) ; Return
			UsesType( xtype._alias )
			Return
		Endif
		
		Local ctype:=Cast<ClassType>( type )
		If ctype
			UsesFile( ctype.transFile )
			Return
		Endif
		
		Local atype:=Cast<ArrayType>( type )
		If atype
			'would rather not have to use array element type too, but it's complicated...
			UsesType( atype.elemType )
			Return
		Endif
		
		RefsType( type )
	End
	
	Method RefsType( type:Type )
		
		Local xtype:=Cast<AliasType>( type )
		If xtype
			If xtype.adecl.IsExtern UsesFile( xtype.transFile ) ; Return
			RefsType( xtype._alias )
			Return
		Endif
		
		Local ctype:=Cast<ClassType>( type )
		If ctype
			'Note: Have to include extern type definitons
			If ctype.cdecl.IsExtern UsesFile( ctype.transFile ) ; Return
			If AddRef( ctype ) _deps.refsTypes.Push( ctype )
			Return
		Endif
		
		Local etype:=Cast<EnumType>( type )
		If etype
			If AddRef( etype ) _deps.refsTypes.Push( etype )
			Return
		Endif
		
		Local ftype:=Cast<FuncType>( type )
		If ftype
			RefsType( ftype.retType )
			For Local type:=Eachin ftype.argTypes
				RefsType( type )
			Next
			Return
		Endif
		
		Local atype:=Cast<ArrayType>( type )
		If atype
			RefsType( atype.elemType )
			Return
		Endif
		
		Local ptype:=Cast<PointerType>( type )
		If ptype
			RefsType( ptype.elemType )
			Return
		Endif
		
	End
End
