#!/usr/bin/perl -w

use strict;
no warnings qw(numeric);
use utf8;

## cpan module for regular expresion engine / trie data structure / optimization
use Regexp::Assemble;

## cpan module for leet speak
use Acme::LeetSpeak;

## initialize regular expression engine and enable tracker
my $ra = Regexp::Assemble->new(track => 1);

## profane words for april 2016, hackathon
my $filename = 'base_profanity_list.txt';

## special characters replacement hash
my %special_character = (
's' , '$',
'i' , '!',
'l' , '1',
'a' , '@',
'e' , '3',
'g' , '8',
'o' , '0',
'h' , '#',
't' , '+',
'u' , '4'
);

## add family context for salacious words less than 3 characters in length
    
my $family_context = 'mother|mothered|motherhood|mothering|motherland|motherless|motherlike|motherly|mothers|motherwort|father|fathered|fatherhood|fathering|fatherland|fatherless|fatherlike|fatherly|fathers|fathership|stepfather|stepsister|stepson|stepsons|sis|sisal|siseraries|siserary|siskin|siskins|siss|sisses|sissier|sissies|sissiest|sissified|sissoo|sissoos|sissy|sist|sisted|sister|sistered|sisterhood|sistering|sisterless|sisterly|sisters|sisting|holy|holystone|holystoned|holystones';

## replacement symbols array
my @symbols = ('@', '#', '$', '%', '^', '&', '*', '_');

## open profanity list file, and start generation regular expressions for capturing variations
    open(my $fh , $filename) or die "Could not open file '$filename' $!";

my @leet_list = ();
my @phonetic_list = ();
my @symbol_list = ();

while (my $word = <$fh>) {
    
    chomp $word;
    
    $word = lc $word;
    
    ## leet processing
    
    (my $leet_word = $word) =~ s/\.\*//ig;
    
    if (length($leet_word) > 2) {
        
        my $leet_copy = leet ($leet_word);
        
        push ( @leet_list, $leet_copy );
        
    }
    
    ## general regex
    
    if ($word !~ /[[:punct:]]/) {
        
        (my $copy = $word) =~ s/(^.*$)/\\b$1\\b/ig;
        
        $ra->add($copy);
    }
    
    elsif ($word =~ /^\.\*|\.\*$/) {
        
        $ra->add($word);
        
    }
    else {
        
        my $copy = quotemeta ( $word );
        
        $copy =~ s/(^.*$)/\\b$1\\b/ig;
        
        $ra->add($copy);
        
    }
    
    ## rotating vowel removal regex
    
    my @vowels = $word =~ /[aeiuo]/gi;
    
    for (my $i = 0; $i < @vowels; $i++) {
        
        
        (my $copy = $word) =~ s/$vowels[$i]//i;
        
        (my $incre_vowel = $copy) =~ s/\.\*//ig;
        
        if ($copy !~ /[[:punct:]]/) {
            
            if (length ($copy) > 5) {
                
                (my $copy_vowel = $copy) =~ s/(^.*$)/\\b$1\\b/ig;
                
                $ra->add($copy_vowel);
                
            }
            else {
                
                (my $copy_vowel = $copy) =~ s/(^.*$)/\\b($family_context)\\s*$1\\b/ig;
                
                $ra->add($copy_vowel);
            }
        }
        
        elsif ($copy =~ /^\.\*|\.\*$/) {
            
            if (length ($incre_vowel) > 5 ) {
            	
            	(my $copy_vowel = $incre_vowel) =~ s/(^.*$)/\\b$1\\b/ig;
                
               $ra->add($copy_vowel);
                
            }
            else {
                
                (my $copy_vowel = $incre_vowel) =~ s/(^.*$)/\\b($family_context)\\s*$1\\b/ig;
                
                $ra->add($copy_vowel);
            }
        }
        else {
            
            my $copy_meta = quotemeta ( $copy );
            
            if (length ($copy) > 5 ) {
                
                (my $copy_vowel = $copy_meta) =~ s/(^.*$)/\\b$1\\b/ig;
                
                
                $ra->add($copy_vowel);
                
            }
            else {
                
                (my $copy_vowel = $copy_meta) =~ s/(^.*$)/\\b($family_context)\\s*$1\\b/ig;
                
                $ra->add($copy_vowel);
            }
        }
    }
    
    ## all vowels removal regex
    
    (my $rem_vowel = $word) =~ s/[aeiuo]//ig;
    
    (my $rem_all_vowels = $rem_vowel) =~ s/\.\*//ig;
    
    if ($rem_vowel !~ /[[:punct:]]/) {
        
        if (length ($rem_vowel) > 5 ) {
            
            (my $copy_vowel = $rem_vowel) =~ s/(^.*$)/\\b$1\\b/ig;
            
            $ra->add($copy_vowel);
            
        }
        else {
            
            (my $copy_vowel = $rem_vowel) =~ s/(^.*$)/\\b($family_context)\\s*$1\\b/ig;
            
            $ra->add($copy_vowel);
        }
    }
    
    elsif ($rem_vowel =~ /^\.\*|\.\*$/) {
        
        if (length ($rem_all_vowels) > 5 ) {
        	
        	(my $copy_vowel = $rem_all_vowels) =~ s/(^.*$)/\\b$1\\b/ig;
    
           $ra->add($copy_vowel);
            
        }
        else {
            
            (my $copy_vowel = $rem_all_vowels) =~ s/(^.*$)/\\b($family_context)\\s*$1\\b/ig;
            
            $ra->add($copy_vowel);
        }
    }
    else {
        
        my $copy_meta = quotemeta ( $rem_vowel );
        
        if (length ($rem_vowel) > 5 ) {
            
            (my $copy_vowel = $copy_meta) =~ s/(^.*$)/\\b$1\\b/ig;
            
            
            $ra->add($copy_vowel);
            
        }
        else {
            
            (my $copy_vowel = $copy_meta) =~ s/(^.*$)/\\b($family_context)\\s*$1\\b/ig;
            
            $ra->add($copy_vowel);
        }
    }
    
    ## rotating symbol replacements regex
    
    (my $symbol_word = $word) =~ s/\.\*//ig;
    
    if (($symbol_word =~ /^[a-zA-Z]+$/) && (length($symbol_word) > 3)) {
        
        my @letters = split('', $symbol_word);
        
        
        for (my $i = 0; $i < @symbols; $i++) {
            
            for (my $j = 0; $j < @letters; $j++) {
                
                
                (my $copy = $symbol_word) =~ s/$letters[$j]/$symbols[$i]/i;
                
                push ( @symbol_list, $copy);
                
            }
        }
    }
    
    ## rotating symbol / leet / consecutive letter transposition regex
    
    if (($word !~ /^\.\*|\.\*$/) && (length ($word) > 4 )) {
        
        push ( @phonetic_list, $word);
    }
}

## print contents of regular expression engine for debugging purposes
    
##print $ra->re . "\n";

## hash of leet processed salacious words
our	%hash_leet 	=	map { $_ => 1 }	 @leet_list;

my @tranposed_profanity  = ();

for my $weather_element (@phonetic_list) {
    
    my @shuffled =  transposition( $weather_element );
    
    push (@tranposed_profanity, @shuffled );
    
    
}


@symbol_list = uniq ( @symbol_list );

for my $weather_element (@symbol_list) {
    
    my @shuffled =  transposition_symbols ( $weather_element );
    
    push (@tranposed_profanity, @shuffled );
    
    
}


push (@tranposed_profanity, @symbol_list);

@tranposed_profanity = uniq ( @tranposed_profanity );


our	%hash_transposed_profanity 	=	map { $_ => 1 }	 @tranposed_profanity;

##print "Ready for input\n";
    
while(my $line = <STDIN>) {
    
    
    chomp $line;
    
    ## enable unit testing
    
    ## my 	@master_split	=	split(','	,	$line	, -1 );
    
    ## parser for reading in cons na at /hdfs/Abilitec/Cons_NA/Mar2016/part*
        
    my 	@cur	=	split(','	,	$line	, -1 );
    
    my $ock=$cur[0]||= '';
    my $fn=$cur[5]||= '';
    my $ln=$cur[7]||= '';
    
    my @master_split = ();
    
   
    if ($fn ne '') {
    	
    	 push ( @master_split, $fn);
    	
    	
    }
    if ($ln ne '') {
    	
    	 push ( @master_split, $ln);
    	
    	
    }
    
  
    my $found_salacious = '0';
    
    
    for my $indi_word (@master_split) {
        
        chomp $indi_word;
        
        $indi_word = lc $indi_word;
        
        
        (my $remove_punct_word = $indi_word) =~ s/[[:punct:]]|\s+//g;
        
        my 	@split_indi	=	split(' '	,	$indi_word , -1 );
        
       
        ## check if name has only symbols
            
        if (($indi_word !~ /[\p{L}]+/) && (length($indi_word) > 4) && ($indi_word !~ /^[0-9]+$/)) {
            
            print "detail,$indi_word contains profanity ( ONLY SYMBOLS ): $indi_word,1\n";
            print STDERR "reporter:counter:SALACIOUS,ONLY SYMBOLS,1\n";            
            $found_salacious = '1';
            last;
        }
        
        ## check if name has matched with salacious word in regular expression engine
            
        if (($indi_word =~ /$ra/i) || ($remove_punct_word =~ /$ra/i)) {
            
            print "detail,$indi_word contains profanity ( REGEXP ):" . $ra->source($^R) . ",1" . "\n";
            print STDERR "reporter:counter:SALACIOUS,REGEXP,1\n";            
            $found_salacious = '1';
            last;
        }
        
        ## check if name has matched with hash of salacious word transpositions
            
        if ( length ( $indi_word) >= 3 ) {
            
            my $edit_found = '0';
            
            for my $weather_element (@split_indi) {
            	
                
                if ((exists($hash_transposed_profanity{$weather_element}) && ($weather_element ne '')) || (exists($hash_transposed_profanity{$remove_punct_word}))) {
                    
                    print "detail,$indi_word contains profanity ( TRANSPOSITION/SYMBOLS/VOWELS ),1\n";
                    print STDERR "reporter:counter:SALACIOUS,TRANSPOSITION/SYMBOLS/VOWELS,1\n";                    
                    $found_salacious = '1';
                    $edit_found = '1';
                    last;
                }
            }
          
            if ($edit_found eq '1') {
                last;
            }
        }
        
        ## check if name has matched with salacious leet word
            
        if ( length ( $indi_word) > 4 ) {
            
            my $edit_found = '0';
            
            
            for my $weather_element (@split_indi) {
            	
            if ($weather_element ne '') {
                
                if (exists($hash_leet{$weather_element})) {
                    
                    print "detail,$indi_word contains profanity ( LEET SPEAK ),1\n";
                    print STDERR "reporter:counter:SALACIOUS,LEET SPEAK,1\n";                    
                    $found_salacious = '1';
                    $edit_found = '1';
                    last;
                }
            }
          }
            if ($edit_found eq '1') {
                last;
            }
        }
    }
    
    if ($found_salacious eq '1') {
        print "output,$ock,1\n";
        ##print "$ock,1\n";
    }
    else {
        print "output,$ock,0\n";
        ##print "$ock,0\n";
    }
}

## returns a unique array of elements

sub uniq {
    my %seen;
    return grep { !$seen{$_}++ } @_;
}

## transposes symbols and returns a transposed array of words

sub transposition_symbols {
    
    my ($profane_word) = @_;
    
    my @profane_transposed = ();
    
    for my $i (1 .. length($profane_word)-2) {
        
        (my $tmp = $profane_word) =~ s/(.{$i})(.)(.)/$1$3$2/;
        
        push ( @profane_transposed, $tmp );
    }
    
    
    return @profane_transposed;
}

## transposes consecutive elements along with symbol and leet substitutions

sub transposition {
    
    my ($profane_word) = @_;
    
    my @profane_transposed = ();
    
    if (length($profane_word) <= 4) {
        
        for my $i (1 .. length($profane_word)-2) {
            
            (my $tmp = $profane_word) =~ s/(.{$i})(.)(.)/$1$3$2/;
            
            push ( @profane_transposed, $tmp );
        }
    }
    else {
        
        for my $i (1 .. length($profane_word)-4) {
            
            (my $tmp = $profane_word) =~ s/(.{$i})(.)(.)/$1$3$2/;
            
            push ( @profane_transposed, $tmp );
        }
    }
    
    
    for (my $i = 1; $i < (length($profane_word) -1); $i++) {
        
        push ( @profane_transposed, join ( '', substr($profane_word, 0, $i),'**',substr($profane_word, $i+2, length($profane_word))));
        push ( @profane_transposed, join ( '', substr($profane_word, 0, $i),'--',substr($profane_word, $i+2, length($profane_word))));
        push ( @profane_transposed, join ( '', substr($profane_word, 0, $i),'@@',substr($profane_word, $i+2, length($profane_word))));
        push ( @profane_transposed, join ( '', substr($profane_word, 0, $i),'##',substr($profane_word, $i+2, length($profane_word))));
        push ( @profane_transposed, join ( '', substr($profane_word, 0, $i),'$$',substr($profane_word, $i+2, length($profane_word))));
        push ( @profane_transposed, join ( '', substr($profane_word, 0, $i),'%%',substr($profane_word, $i+2, length($profane_word))));
        push ( @profane_transposed, join ( '', substr($profane_word, 0, $i),'^^',substr($profane_word, $i+2, length($profane_word))));
        push ( @profane_transposed, join ( '', substr($profane_word, 0, $i),'&&',substr($profane_word, $i+2, length($profane_word))));
        push ( @profane_transposed, join ( '', substr($profane_word, 0, $i),'__',substr($profane_word, $i+2, length($profane_word))));
        
    }
    
    for my $ele (keys %special_character) {
        
        if ($profane_word =~ m/$ele/) {
            
            my $rep_word = $profane_word;
            
            $rep_word =~ s/$ele/$special_character{$ele}/ig;
            
            push ( @profane_transposed, $rep_word);
            
            for my $i (1 .. length($rep_word)-2) {
                
                (my $tmp = $rep_word) =~ s/(.{$i})(.)(.)/$1$3$2/;
                
                push ( @profane_transposed, $tmp );
            }
        }
    }
    
    return @profane_transposed;
}