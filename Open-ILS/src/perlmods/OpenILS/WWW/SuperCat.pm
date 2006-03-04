package OpenILS::WWW::SuperCat;
use strict; use warnings;

use Apache2 ();
use Apache2::Log;
use Apache2::Const -compile => qw(OK REDIRECT DECLINED :log);
use APR::Const    -compile => qw(:error SUCCESS);
use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::RequestUtil;
use CGI;
use Data::Dumper;

use OpenSRF::EX qw(:try);
use OpenSRF::System;
use OpenSRF::AppSession;
use XML::LibXML;

use OpenILS::Utils::Fieldmapper;


# set the bootstrap config when this module is loaded
my ($bootstrap, $supercat);

sub import {
	my $self = shift;
	$bootstrap = shift;
}


sub child_init {
	OpenSRF::System->bootstrap_client( config_file => $bootstrap );
	$supercat = OpenSRF::AppSession->create('open-ils.supercat');
}

sub oisbn {

	my $apache = shift;
	return Apache2::Const::DECLINED if (-e $apache->filename);

	(my $isbn = $apache->path_info) =~ s{^.*?([^/]+)$}{$1}o;

	my $list = $supercat
		->request("open-ils.supercat.oisbn", $isbn)
		->gather(1);

	print "Content-type: application/xml; charset=utf-8\n\n";
	print "<?xml version='1.0' encoding='UTF-8' ?>\n";

	unless (exists $$list{metarecord}) {
		print '<idlist/>';
		return Apache2::Const::OK;
	}

	print "<idlist metarecord='$$list{metarecord}'>\n";

	for ( keys %{ $$list{record_list} } ) {
		(my $o = $$list{record_list}{$_}) =~s/^(\S+).*?$/$1/o;
		print "  <isbn record='$_'>$o</isbn>\n"
	}

	print "</idlist>\n";

	return Apache2::Const::OK;
}

sub unapi {

	my $apache = shift;
	return Apache2::Const::DECLINED if (-e $apache->filename);

	print "Content-type: application/xml; charset=utf-8\n";
	
	my $cgi = new CGI;

	my $uri = $cgi->param('uri') || '';
	my $base = $cgi->url;
	my $host = $cgi->virtual_host || $cgi->server_name;

	my $format = $cgi->param('format');
	my ($id,$type,$command) = ('','','');

	if (!$format) {
		if ($uri =~ m{^tag:[^:]+:([^\/]+)/(\d+)}o) {
			$id = $2;
			$type = 'record';
			$type = 'metarecord' if ($1 =~ /^m/o);

			my $list = $supercat
			->request("open-ils.supercat.$type.formats")
				->gather(1);

			print "\n";

			my $body =
				"<formats>
				 <uri>$uri</uri>
				   <format>
				     <name>opac</name>
				     <type>text/html</type>
				   </format>";

			for my $h (@$list) {
				my ($type) = keys %$h;
				$body .= "<format><name>$type</name><type>application/$type+xml</type>";

				for my $part ( qw/namespace_uri docs schema_location/ ) {
					$body .= "<$part>$$h{$type}{$part}</$part>"
						if ($$h{$type}{$part});
				}
				
				$body .= '</format>';
			}

			$body .= "</formats>\n";

			$apache->custom_response( 300, $body);
			return 300;
		} else {
			my $list = $supercat
				->request("open-ils.supercat.record.formats")
				->gather(1);
				
			push @$list,
				@{ $supercat
					->request("open-ils.supercat.metarecord.formats")
					->gather(1);
				};

			my %hash = map { ( (keys %$_)[0] => (values %$_)[0] ) } @$list;
			$list = [ map { { $_ => $hash{$_} } } sort keys %hash ];

			print "\n<formats>
				   <format>
				     <name>opac</name>
				     <type>text/html</type>
				   </format>";

			for my $h (@$list) {
				my ($type) = keys %$h;
				print "<format><name>$type</name><type>application/$type+xml</type>";

				for my $part ( qw/namespace_uri docs schema_location/ ) {
					print "<$part>$$h{$type}{$part}</$part>"
						if ($$h{$type}{$part});
				}
				
				print '</format>';
			}

			print "</formats>\n";


			return Apache2::Const::OK;
		}
	}

		
	if ($uri =~ m{^tag:[^:]+:([^\/]+)/(\d+)}o) {
		$id = $2;
		$type = 'record';
		$type = 'metarecord' if ($1 =~ /^m/o);
		$command = 'retrieve';
	}

	if ($format eq 'opac') {
		print "Location: $base/../../en-US/skin/default/xml/rresult.xml?m=$id\n\n"
			if ($type eq 'metarecord');
		print "Location: $base/../../en-US/skin/default/xml/rdetail.xml?r=$id\n\n"
			if ($type eq 'record');
		return 302;
	}

	print "\n" . $supercat->request("open-ils.supercat.$type.$format.$command",$id)->gather(1);

	return Apache2::Const::OK;
}

sub supercat {

	my $apache = shift;
	return Apache2::Const::DECLINED if (-e $apache->filename);

	my $path = $apache->path_info;

	my $cgi = new CGI;
	my $base = $cgi->url;

	my ($id,$type,$format,$command) = reverse split '/', $path;

	print "Content-type: application/xml; charset=utf-8\n";
	
	if ( $path =~ m{^/formats(?:/([^\/]+))?$}o ) {
		if ($1) {
			my $list = $supercat
				->request("open-ils.supercat.$1.formats")
				->gather(1);

			print "\n";

			print "<formats>
				   <format>
				     <name>opac</name>
				     <type>text/html</type>
				   </format>";

			for my $h (@$list) {
				my ($type) = keys %$h;
				print "<format><name>$type</name><type>application/$type+xml</type>";

				for my $part ( qw/namespace_uri docs schema_location/ ) {
					print "<$part>$$h{$type}{$part}</$part>"
						if ($$h{$type}{$part});
				}
				
				print '</format>';
			}

			print "</formats>\n";

			return Apache2::Const::OK;
		}

		my $list = $supercat
			->request("open-ils.supercat.record.formats")
			->gather(1);
				
		push @$list,
			@{ $supercat
				->request("open-ils.supercat.metarecord.formats")
				->gather(1);
			};

		my %hash = map { ( (keys %$_)[0] => (values %$_)[0] ) } @$list;
		$list = [ map { { $_ => $hash{$_} } } sort keys %hash ];

		print "\n<formats>
			   <format>
			     <name>opac</name>
			     <type>text/html</type>
			   </format>";

		for my $h (@$list) {
			my ($type) = keys %$h;
			print "<format><name>$type</name><type>application/$type+xml</type>";

			for my $part ( qw/namespace_uri docs schema_location/ ) {
				print "<$part>$$h{$type}{$part}</$part>"
					if ($$h{$type}{$part});
			}
			
			print '</format>';
		}

		print "</formats>\n";


		return Apache2::Const::OK;
	}

	if ($format eq 'opac') {
		print "Location: $base/../../en-US/skin/default/xml/rresult.xml?m=$id\n\n"
			if ($type eq 'metarecord');
		print "Location: $base/../../en-US/skin/default/xml/rdetail.xml?r=$id\n\n"
			if ($type eq 'record');
		return 302;
	}

	print "\n" . $supercat->request("open-ils.supercat.$type.$format.$command",$id)->gather(1);

	return Apache2::Const::OK;
}

1;
