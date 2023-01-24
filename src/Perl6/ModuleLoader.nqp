my $rakudo-module-debug := nqp::atkey(nqp::getenvhash(), 'RAKUDO_MODULE_DEBUG');
my $DEBUG := nqp::stmts((my $debug-radix := nqp::radix(10, $rakudo-module-debug, 0, 0)),($debug-radix[2] != -1))
?? ?$debug-radix[0] !! ?nqp::chars($rakudo-module-debug);
sub DEBUG(*@strs) {
    my $err := stderr();
    $err.print(" " ~ $rakudo-module-debug ~ nqp::x(" ", ($rakudo-module-debug - 1) * 4) ~ " RMD: ");
    for @strs { $err.print($_) };
    $err.print("\n");
    1;
}

class Perl6::ModuleLoader does Perl6::ModuleLoaderVMConfig {
    my %modules_loaded;
    my %settings_loaded;
    my $absolute_path_func;

    my %language_module_loaders := nqp::hash(
        'NQP', nqp::gethllsym('nqp', 'ModuleLoader'),
    );

    method register_language_module_loader($lang, $loader, :$force) {
        nqp::die("Language loader already registered for $lang")
            if ! $force && nqp::existskey(%language_module_loaders, $lang);
        %language_module_loaders{$lang} := $loader;
    }

    method register_absolute_path_func($func) {
        $absolute_path_func := $func;
    }

    method absolute_path($path) {
        $absolute_path_func ?? $absolute_path_func($path) !! $path;
    }

    method ctxsave() {
        $*MAIN_CTX := nqp::ctxcaller(nqp::ctx());
        $*CTXSAVE := 0;
    }

    method search_path() {
        self.vm_search_paths()
    }

    method load_module($module_name, %opts, *@GLOBALish, :$line, :$file, :%chosen) {
        DEBUG("going to load $module_name") if $DEBUG;
        if nqp::eqat($module_name, 'Perl6::BOOTSTRAP::v6', 0) {
            my $preserve_global := nqp::gethllsym('Raku', 'GLOBAL');
            my %*COMPILING := {};
            my $*CTXSAVE := self;
            my $*MAIN_CTX;
            my $file := nqp::join('/', nqp::split('::', $module_name)) ~ self.file-extension;

            my @prefixes := self.search_path();
            for @prefixes -> $prefix {
                if nqp::stat("$prefix/$file", 0) {
                    $file := "$prefix/$file";
                    last;
                }
            }

            if nqp::existskey(%modules_loaded, $file) {
                return nqp::ctxlexpad(%modules_loaded{$file});
            }

            nqp::loadbytecode($file);
            %modules_loaded{$file} := my $module_ctx := $*MAIN_CTX;
            nqp::bindhllsym('Raku', 'GLOBAL', $preserve_global);
            my $UNIT := nqp::ctxlexpad($module_ctx);
            if +@GLOBALish {
                unless nqp::isnull($UNIT<GLOBALish>) {
                    self.merge_globals(@GLOBALish[0].WHO, $UNIT<GLOBALish>.WHO);
                }
            }
            return $UNIT;
        }
        if nqp::existskey(%language_module_loaders, %opts<from> // 'NQP') {
            # We expect that custom module loaders will accept a Stash, only
            # NQP expects a hash and therefor needs special handling.
            if %opts<from> eq 'NQP' {
                if +@GLOBALish {
                    my $target := nqp::knowhow().new_type(:name('GLOBALish'));
                    nqp::setwho($target, @GLOBALish[0].WHO.FLATTENABLE_HASH());
                    return %language_module_loaders<NQP>.load_module($module_name, $target);
                }
                else {
                    return %language_module_loaders<NQP>.load_module($module_name);
                }
            }
            return %language_module_loaders{%opts<from>}.load_module($module_name,
                %opts, |@GLOBALish, :$line, :$file);
        }
        else {
            nqp::die("Do not know how to load code from " ~ %opts<from>);
        }
    }

    # This is a first cut of the globals merger. For another approach,
    # see sorear++'s work in Niecza. That one is likely more "pure"
    # than this, but that would seem to involve copying too, and the
    # details of exactly what that entails are a bit hazy to me at the
    # moment. We'll see how far this takes us.
    my $stub_how_name := 'Perl6::Metamodel::PackageHOW';
    my $nqp_stub_how_name := 'KnowHOW';
    sub is_HOW_stub($target) {
         my $how  := $target.HOW;
         my $name := $how.HOW.name($how);
         $name eq $stub_how_name || $name eq $nqp_stub_how_name
    }
    method merge_globals($target, $source) {
        my $metamodel-configuration := nqp::gethllsym('Raku', 'METAMODEL_CONFIGURATION');
        if !nqp::isnull($metamodel-configuration) && nqp::istype($target, $metamodel-configuration.stash_type()) {
            # merge-symbols will loop back on this method again, but would lock-protect itself first.
            $target.merge-symbols($source);
        }
        elsif stash_hash($source) -> %source {
            # Start off merging top-level symbols. Easy when there's no
            # overlap. Otherwise, we need to recurse.
            my %known_symbols;
            my $iter := nqp::iterator(stash_hash($target));
            nqp::while(
              $iter,
              nqp::bindkey(%known_symbols,nqp::iterkey_s(nqp::shift($iter)),1)
            );
            for sorted_keys(%source) -> $sym {
                my $value := %source{$sym};
                if nqp::not_i(%known_symbols{$sym}) {
                    $target{$sym} := $value;
                }
                elsif nqp::decont(my $target_sym := $target{$sym}) =:=
                  nqp::decont($value) { # Stash entries are containerized
                    # No problemo; a symbol can't conflict with itself.
                }
                elsif is_HOW_stub($value) {
                    # Since the source is a stub, it doesn't matter whether
                    # the target is also a stub or not.  In either case,
                    # it is fine to merge source symbols into target.
                    self.merge_globals($target_sym.WHO, $value.WHO);
                }
                elsif is_HOW_stub($target_sym) {
                    # The tricky case: here the interesting package is the
                    # one in the module. So we merge the other way around
                    # and install that as the result.
                    self.merge_globals($value.WHO, $target_sym.WHO);
                    $target{$sym} := $value;
                }
                elsif nqp::eqat($sym, '&', 0) {
                    # "Latest wins" semantics for functions
                    $target{$sym} := $value;
                }
                else {
                    # Potentially do other conflict resolution in the future
                    nqp::die("Merging GLOBAL symbols failed: duplicate definition of symbol $sym");
                }
            }
        }
    }
    method merge_globals_lexically($world, $target, $source) {
        if stash_hash($source) -> %source {
            # Start off merging top-level symbols. Easy when there's no
            # overlap. Otherwise, we need to recurse.
            for sorted_keys(%source) -> $sym {
                my %known_symbols;
                my $iter := nqp::iterator(stash_hash($target.symtable));
                nqp::while(
                  $iter,
                  nqp::bindkey(
                    %known_symbols,
                    nqp::iterkey_s(nqp::shift($iter)),
                    nqp::iterval($iter)<value>
                  )
                );
                my $value := %source{$sym};
                my $outer := 0;
                if nqp::not_i(nqp::existskey(%known_symbols, $sym)) {
                    try {
                        %known_symbols{$sym} := $world.find_single_symbol($sym);
                        $outer := 1;
                    }
                }
                if nqp::not_i(nqp::existskey(%known_symbols, $sym)) {
                    $target.symbol($sym, :scope<lexical>, :$value);
                    $target[0].push(QAST::Var.new(
                      :scope<lexical>, :name($sym), :decl<static>, :$value
                    ));
                    $world.add_object_if_no_sc($value);
                }
                elsif nqp::decont(my $known_sym := %known_symbols{$sym}) =:=
                  nqp::decont($value) { # Stash entries are containerized
                    # No problemo; a symbol can't conflict with itself.
                }
                elsif is_HOW_stub($value) {
                    # Since the source is a stub, it doesn't matter whether
                    # the target is also a stub or not.  In either case,
                    # it is fine to merge source symbols into target.
                    self.merge_globals($known_sym.WHO, $value.WHO);
                }
                elsif is_HOW_stub($known_sym) {
                    # The tricky case: here the interesting package is the
                    # one in the module. So we merge the other way around
                    # and install that as the result.
                    self.merge_globals($value.WHO, $known_sym.WHO);
                    $target.symbol($sym, :scope<lexical>, :$value);
                }
                elsif $outer || nqp::eqat($sym, '&', 0) {
                    # ok to overwrite non-stub symbols of outer lexical scopes
                    # or "latest wins" semantics for functions
                    $target.symbol($sym, :scope<lexical>, :$value);
                }
                else {
                    nqp::die("Merging GLOBAL symbols failed: duplicate definition of symbol $sym");
                }
            }
        }
    }

    # Transforms NULL.<release> into CORE.<previous-release>, CORE.<release> into CORE.<previous-release>
    method previous_setting_name ($setting_name, :$base = 'CORE') {
        nqp::gethllsym('default', 'SysConfig').rakudo-build-config()<prev-setting-name>{$setting_name}
            // nqp::die("Don't know setting $setting_name")
    }

    method transform_setting_name ($setting_name) {
        return self.previous_setting_name($setting_name, base => 'NULL');
    }

    my $setting-lock := NQPLock.new;
    method load_setting($setting_name) {
        my $setting;

        if $setting_name ne 'NULL.c' {
            CATCH {
                nqp::unlock($setting-lock);
                nqp::can($_, 'rethrow') ?? $_.rethrow !! nqp::rethrow($_);
            }
            nqp::lock($setting-lock);

            DEBUG("Requested for settings $setting_name") if $DEBUG;
            $setting_name := self.transform_setting_name($setting_name);

            # First, pre-load previous setting.
            my $prev_setting_name := self.previous_setting_name($setting_name);
            my $prev_setting;
            # Don't do this for .c for which $setting_name doesn't change
            unless nqp::iseq_s($prev_setting_name, $setting_name) {
                $prev_setting := self.load_setting($prev_setting_name);
            }

            # Unless we already did so, locate and load the setting.
            if nqp::defined(%settings_loaded{$setting_name}) {
                DEBUG("Settings $setting_name already loaded") if $DEBUG;
            }
            else {
                DEBUG("Loading settings $setting_name") if $DEBUG;
                # Find it.
                my $path := self.find_setting($setting_name);

                # Load it.
                my $*CTXSAVE := self;
                my $*MAIN_CTX;
                my $preserve_global := nqp::gethllsym('Raku','GLOBAL');

                DEBUG("Loading bytecode from $path") if $DEBUG;
                nqp::scwbdisable();
                nqp::loadbytecode($path);
                nqp::scwbenable();
                nqp::bindhllsym('Raku', 'GLOBAL', $preserve_global);

                unless nqp::defined($*MAIN_CTX) {
                    nqp::die("Unable to load setting $setting_name; maybe it is missing a YOU_ARE_HERE?");
                }
                nqp::forceouterctx(nqp::ctxcode($*MAIN_CTX),$prev_setting)
                  if nqp::defined($prev_setting);
                %settings_loaded{$setting_name} := $*MAIN_CTX;

                DEBUG("Settings $setting_name loaded") if $DEBUG;
            }

            $setting := %settings_loaded{$setting_name};
            nqp::unlock($setting-lock);
        }

        return $setting;
    }

    # Handles any object repossession conflicts that occurred during module load,
    # or complains about any that cannot be resolved.
    method resolve_repossession_conflicts(@conflicts) {
        for @conflicts -> $orig, $current {
            # If it's a Stash in conflict, we make sure any original entries get
            # appropriately copied.
            if $orig.HOW.name($orig) eq 'Stash' {
                for $orig.FLATTENABLE_HASH() {
                    if !nqp::existskey($current, $_.key) || nqp::eqat($_.key, '&', 0) {
                        $current{$_.key} := $_.value;
                    }
                }
            }
            # We could complain about anything else, and may in the future; for
            # now, we let it pass by with "latest wins" semantics.
        }
    }

    sub stash_hash($pkg) {
        nqp::ishash($pkg) ?? $pkg !! $pkg.FLATTENABLE_HASH()
    }
}

# We stash this in the raku HLL namespace, just so it's easy to
# locate. Note this makes it invisible inside Raku itself.
nqp::bindhllsym('Raku', 'ModuleLoader', Perl6::ModuleLoader);

# vim: expandtab sw=4
