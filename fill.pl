#!/usr/bin/perl

use strict;
use warnings;
use utf8;
binmode(STDOUT, ":utf8");
use open qw/:std :utf8/;
use Encode;
use Term::ANSIColor;
use UI::Dialog;
use Data::Dumper;
use HTML::Entities;
use Storable;
use File::Touch;
use Digest::MD5 qw/md5_hex/;
use File::Slurp;

my %skip_fields = ();
my %db = ();
my %field_original_names = ();

my %options = (
	debug => 0,
	file => undef,
	dbfile => "$ENV{HOME}/.dbfilefiller",
	fillwhatyoucan => 0
);

END {
	write_db();
}

mkdir ".cache" unless -d ".cache";
analyze_args(@ARGV);

sub write_db {
	store \%db, $options{dbfile};
}


sub read_db {
	if(-e $options{dbfile}) {
		%db = %{retrieve($options{dbfile})};
	} else {
		touch($options{dbfile});
	}
}

sub warning (@) {
	foreach (@_) {
		warn color("on_yellow black").$_.color("reset")."\n";
	}
}

sub error (@) {
	foreach (@_) {
		warn color("on_red black").$_.color("reset")."\n";
	}
	exit 1;
}


sub debug (@) {
	if($options{debug}) {
		foreach (@_) {
			warn color("on_green black").$_.color("reset")."\n";
		}
	}
}

sub mysystem {
	foreach (@_) {
		debug $_;
		system($_);
	}
}

my $title = "DocFiller";
my $backtitle = "";

my $d = new UI::Dialog (
	backtitle => $backtitle, 
	title => $title,
	height => 25,
	width => 150, 
	listheight => 15,
	order => ['whiptail', 'gdialog', 'zenity', 'whiptail']
);

sub ucif {
	my $original = shift;
	my $my = shift;
	if ($original =~ /[A-Z]/) {
		return uc($my);
	} else {
		return $my;
	}
}

sub analyze_args {
	foreach (@_) {
		if(m#^--debug$#) {
			$options{debug} = 1;
		} elsif(m#^--fillwhatyoucan$#) {
			$options{fillwhatyoucan} = 1;
		} elsif(m#^--dbfile=(.*)$#) {
			$options{dbfile} = $1;
		} elsif(m#^--file=(.*)$#) {
			my $file = $1;
			if(-e $file) {
				$options{file} = $file;
			} else {
				error "$file not found";

			}
		} else {
			error "Unknown parameter $_";
		}
	}
}

sub qxcache {
	my $command = shift;
	debug "qxcache($command)";
	my $cachefile = ".cache/".md5_hex($command);
	my $string = "";
	if(-e $cachefile) {
		debug "Cachefile $cachefile exists";
		$string = read_file($cachefile);
	} else {
		$string = qx($command);
		open my $fh, '>', $cachefile or error $!;
		print $fh $string;
		close $fh;
	}
	return $string;
}

sub analyze_file {
	my @fields = ();
	my $output = qxcache("pdftk $options{file} dump_data_fields");
	foreach my $field (split /\n?---\n?/, $output) {
		my %this_field = ();
		foreach my $field_line (split /\n/, $field) {
			if($field_line =~ m#^(.*?): (.*)$#) {
				my $name = $1;
				my $value = $2;
				my $string = decode_entities(decode('utf-8', $value));
				$this_field{$name} = $string;
				$field_original_names{$string} = $value;
			}
		}
		if(keys %this_field) {
			push @fields, \%this_field;
		}
	}

	return @fields;
}

sub dinput {
	return if $options{fillwhatyoucan};
	my $text = shift;
	my $entry = shift;
	my $max_length = shift // 0;

	debug "input($text, $entry)";
	my $result = undef;
	if(!$max_length) {
		$result = $d->inputbox( text => $text, entry => $entry);
		if($d->rv()) {
			debug "You chose cancel. Exiting.";
			exit();
		}
	} else {
		while (!defined $result || length($result) > $max_length) {
			$result = $d->inputbox(text => "$text (Max. $max_length Zeichen)", entry => $entry);
			if($d->rv()) {
				debug "You chose cancel. Exiting.";
				exit();
			}
		}
	}

	return $result;
}

sub radio {
	return if $options{fillwhatyoucan};
	my $text = shift;
	my $list = shift;
	my $exit = shift // 1;
	my $selection = $d->radiolist(
		text => $text,
		list => $list
	);
	if($d->rv()) {
		debug "You chose cancel. Exiting.";
		if($exit) {
			exit();
		} else {
			return $d->rv();
		}
	}
	return $selection;
}

sub checklist {
	my $text = shift;
	my $list = shift;
	my $exit = shift // 1;

	my @selection = $d->checklist( text => $text,
		list => $list
	);

	if($d->rv()) {
		debug "You chose cancel. Exiting.";
		if($exit) {
			exit();
		} else {
			return $d->rv();
		}
	}
	return @selection;
}

sub main {
	debug "main";
	read_db();
	if($options{file}) {
		my @fields = analyze_file();

		my %merged_fields = ();
		my @merged_fields_names = ();

		my @selection = map { $_->{FieldName} } @fields;


		my $skip_re = qr#(?:Abschluss.*Bruttolohn)|(?:Name.*und.*Ort)|(?:Monat.*Jahr)|Fachrichtung|(zur.{1,5}ck)|Anzahl|(^(Pg\d+_|Calend|Ruecks|A_|f\d_|Nr\d+))|(^Day\d)|(Jahr|Monat vor)|Sonstiger|^nein|^ja#i;

		foreach my $possible_field (sort { $a->{FieldName} cmp $a->{FieldName} } @fields) {
			my $possible_field_name = $possible_field->{FieldName};
			if(!grep { $_ eq $possible_field_name } @selection) {
				$skip_fields{$possible_field_name} = 1;
			}
			
			if($possible_field_name =~ m#(IBAN)\s*\d+#) {
				my $name = $1;
				push @{$merged_fields{$name}}, $possible_field;
				push @merged_fields_names, $possible_field_name;
				$skip_fields{$possible_field_name} = 1;
			}


			if($possible_field_name =~ m#$skip_re#) {
				$skip_fields{$possible_field_name} = 1;
			}
		}

		if(!$options{fillwhatyoucan}) {
			my @select_fields = [map { $_->{FieldNameAlt} ? $_->{FieldNameAlt} : $_->{FieldName} => [ $_->{FieldName} => !!!exists($skip_fields{$_->{FieldName}}) ] } @fields];
			if(@{$select_fields[0]}) {
				@selection = checklist("Felder", @select_fields);
			}
		}

		foreach my $merged_field (keys %merged_fields) {
			my $max_length = 0;
			map { $max_length += $_->{FieldMaxLength} } @{$merged_fields{$merged_field}};

			$db{$merged_field} = dinput $merged_field, $db{$merged_field}, $max_length;
			write_db();
			my $pos = 0;
			if($db{$merged_field}) {
				foreach my $field (@{$merged_fields{$merged_field}}) {
					my $field_name = $field->{FieldName};
					my $length = $field->{FieldMaxLength};
					$db{$field_name} = substr($db{$merged_field}, $pos, $length);
					write_db();
					$pos += $length;
				}
			}
		}

		foreach my $field (@fields) { # Nur Checkboxen
			my ($field_name, $field_name_alt, $field_type) = ($field->{FieldName}, $field->{FieldNameAlt}, $field->{FieldType});

			next if $skip_fields{$field_name};
			next if $field_name =~ m#$skip_re#;

			my ($desc, $value) = get_desc_value($field_name, $field_name_alt);

			if ($field_type eq "Button") { # Checkboxen
				#next;
				my $select_yes = 0;

				my @field_names_invert = get_inverted_field_name($field_name, @fields);

				if(exists $db{$field_name}) {
					if($db{$field_name} eq "Ja") {
						$select_yes = 1;
					} else {
						$select_yes = 0;
					}
				}

				if($field_name) {
					$db{$field_name} = radio($desc, ["Ja", ["Ausgewaehlt", $select_yes], "Off", ["Nicht ausgewaehlt", !$select_yes]]);
					
					foreach my $field_name_invert (@field_names_invert) {
						if($field_name ne $field_name_invert) {
							print $db{$field_name};
							$db{$field_name_invert} = $db{$field_name} eq "Ja" ? "Nein" : "Ja";
							$skip_fields{$field_name_invert} = 1;
						}
					}
				}
			}
		}

		foreach my $field (@fields) { # Alles was nicht checkbox ist
			my ($field_name, $field_name_alt, $field_type) = ($field->{FieldName}, $field->{FieldNameAlt}, $field->{FieldType});

			next if exists $skip_fields{$field_name};
			next if $field_name =~ m#$skip_re#;

			my ($desc, $value) = get_desc_value($field_name, $field_name_alt);


			if(!defined $field_name_alt) {
				next;
			}

			if($field_name eq "Familienstand") {
				my $list = [
					"ledig" => ["ledig", 1],
					"verheiratet" => ["verheiratet", 0],
					"verwitwet" => ["verwitwet", 0],
					"geschieden" => ["geschieden", 0],
					"Ehe aufgehoben" => ["Ehe aufgehoben", 0],
					"in eingetragener Lebenspartnerschaft" => ["in eingetragener Lebenspartnerschaft", 0],
					"durch Tod aufgelöste Lebenspartnerschaft" => ["durch Tod aufgelöste Lebenspartnerschaft", 0],
					"aufgehobene Lebenspartnerschaft" => ["aufgehobene Lebenspartnerschaft", 0],
					"durch Todeserklärung aufgelöste Lebenspartnerschaft" => ["durch Todeserklärung aufgelöste Lebenspartnerschaft", 0],
					"nicht bekannt" => ["nicht bekannt", 0],
				];

				if(exists $db{$field_name}) {
					foreach (0 .. ((scalar @$list) - 1)) {
						if($_ % 2 == 0) {
							if($list->[$_] eq $db{$field_name}) {
								$list->[$_ + 1][1] = 1; 
							} else {
								$list->[$_ + 1][1] = 0; 
							}
						}
					}
				}
				$db{$field_name} = radio($desc, \@$list);
			} elsif($field_type eq "Text") {
				#next;
				$value = dinput $desc, $value, exists $field->{FieldMaxLength} ? $field->{FieldMaxLength} : 0;
				$db{$field_name} = $value;
			} elsif ($field_type eq "Button") { # Checkboxen
				# ignore, has been handled before
			}
			write_db();
		}
		#die Dumper \%db;
		create_pdf_xml();
	} else {
		error "No --file given";
	}
}

sub get_inverted_field_name {
	my $field_name = shift;
	my @fields = @_;

	my $field_name_invert = $field_name;
	if($field_name =~ m#\bja\b#i) {
		$field_name_invert =~ s#\b(j)a\b#ucif($1, "n", )."ein"#gei;
	} elsif($field_name =~ m#\bnein\b#i) {
		$field_name_invert =~ s#\b(n)ein\b#ucif($1, "j", )."a"#gei;
	}

	if($field_name =~ m#^m.{1,5}nnlich$#) {
		$field_name_invert = "weiblich";
	} elsif ($field_name =~ m#^weiblich$#) {
		$field_name_invert = "männlich";
	}


	REALFIELDNAMES: foreach my $real_field_name (map { $_->{FieldName} } @fields) {
		if($real_field_name =~ m#$field_name_invert#i) {
			$field_name_invert = $real_field_name;
			last REALFIELDNAMES;
		}
	}

	return $field_name_invert;
}

sub create_pdf_xml {
	my $content = qq#<?xml version="1.0" encoding="UTF-8"?>
<xfdf xmlns="http://ns.adobe.com/xfdf/">
<fields>
			#;
		foreach my $key (keys %db) {
			if(exists $db{$key} && length $db{$key}) {
				$content .= qq#
		<field xfdf:original="#.$field_original_names{$key}.qq#" name="#.$field_original_names{$key}.qq#">
			<value>$db{$key}</value>
		</field>
				#;
			}
		}
	$content .= qq#
	</fields>
</xfdf>\n#;
	my $filename = ".".md5_hex($options{file});
	open my $fh, '>', $filename or die $!;
	print $fh $content;
	close $fh;

	my $command = qq#pdftk "$options{file}" fill_form "$filename" output "$options{file}_filled.pdf"#;
	mysystem($command);
	mysystem(qq#evince "$options{file}_filled.pdf"#);
}

sub get_desc_value {
	my ($field_name, $field_name_alt) = @_;
	my $desc = "";
	my $value = "";

	if(defined $field_name_alt && $field_name eq $field_name_alt) {
		$desc = $field_name_alt;
	} else {
		$desc = $field_name;
	}

	if(exists $db{$field_name} && $db{$field_name}) {
		$value = $db{$field_name};
	}

	if(exists($db{$field_name}) && $db{$field_name}) {
		if($db{$field_name} =~ m#^[01]$#) {
			$desc .= " (vorherige Antwort: ".($db{$field_name} ? "Ja" : "Nein").")";
		} elsif(exists $db{$field_name} && length $db{$field_name}) {
			$desc .= " (vorherige Antwort: ".$db{$field_name}.")";
		}
	}

	return +($desc, $value);
}

main();
