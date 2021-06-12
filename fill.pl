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

my %db = ();


my %options = (
	debug => 0,
	file => undef,
	dbfile => "$ENV{HOME}/.dbfilefiller"
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

my $title = "DocFiller";
my $backtitle = "";

my $d = new UI::Dialog (
	backtitle => $backtitle, 
	title => $title,
	height => 20,
	width => 130, 
	listheight => 10,
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
				my $string = decode_entities(decode('utf-8',$2));
				$this_field{$name} = $string;
			}
		}
		if(keys %this_field) {
			push @fields, \%this_field;
		}
	}

	return @fields;
}

sub dinput {
	my ($text, $entry) = @_;
	debug "input($text, $entry)";
	my $result = undef;
	$result = $d->inputbox( text => $text, entry => $entry);
	if($d->rv()) {
		debug "You chose cancel. Exiting.";
		exit();
	}
	return $result;
}

sub radio {
	my $text = shift;
	my $list = shift;
	my $selection = $d->radiolist(
		text => $text,
		list => $list
	);
	if($d->rv()) {
		debug "You chose cancel. Exiting.";
		exit();
	}
	return $selection;
}

sub main {
	debug "main";
	read_db();
	if($options{file}) {
		my @fields = analyze_file();
		foreach my $field (@fields) {
			my ($field_name, $field_name_alt, $field_type) = ($field->{FieldName}, $field->{FieldNameAlt}, $field->{FieldType});

			my $desc = "";
			my $value = "";

			if(!defined $field_name_alt) {
				next;
				die Dumper $field;
			}

			if($field_name eq $field_name_alt) {
				$desc = "$field_name_alt";
			} else {
				$desc = "$field_name_alt";
			}

			if($db{$field_name}) {
				$value = $db{$field_name};
			}

			if(exists($db{$field_name})) {
				if($db{$field_name} =~ m#^[01]$#) {
					$desc .= " (vorherige Antwort: ".($db{$field_name} ? "Ja" : "Nein").")";
				} elsif(exists $db{$field_name} && length $db{$field_name}) {
					$desc .= " (vorherige Antwort: ".$db{$field_name}.")";
				}
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
				$value = dinput $desc, $value;
				$db{$field_name} = $value;
			} elsif ($field_type eq "Button") {
				#next;
				my $select_yes = 0;

				my $field_name_invert = $field_name;
				if($field_name =~ m#\bja\b#i) {
					$field_name_invert =~ s#\b(j)a\b#ucif($1, "n", )."ein"#gei;
				} elsif($field_name =~ m#\bnein\b#i) {
					$field_name_invert =~ s#\b(n)ein\b#ucif($1, "j", )."ja"#gei;
				}
				
				if($field_name =~ m#^m.{1,5}nnlich$#) {
					$field_name_invert = "weiblich";
				} elsif ($field_name =~ m#^weiblich$#) {
					$field_name_invert = "männlich";
				}


				if(exists $db{$field_name}) {
					if($db{$field_name} == 0) {
						$select_yes = 0;
					} else {
						$select_yes = 1;
					}
				}

				$db{$field_name} = radio($desc, ["Ja", ["Ja", $select_yes], "Nein", ["Nein", !$select_yes]]) eq "Ja" ? 1 : 0;
				
				if($field_name ne $field_name_invert) {
					$db{$field_name_invert} = !$db{$field_name};
				}
			} else {
				warning "Unknown field type";
				die Dumper $field;
			}
			write_db();
		}
	} else {
		error "No --file given";
	}
}

main();
