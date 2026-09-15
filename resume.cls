\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{resume}[2026/08/26 Compact single-page resume class]
\LoadClass[10pt]{article}

\setlength{\parindent}{0pt}
\setlength{\parskip}{0pt}

\RequirePackage{xltxtra}
\RequirePackage[absolute,overlay]{textpos}
\RequirePackage{xifthen}
\RequirePackage[usenames,dvipsnames]{xcolor}
\RequirePackage{fontspec}
\RequirePackage{graphicx}
\RequirePackage{tikz}
\RequirePackage{titlesec}
\RequirePackage{enumitem}
\RequirePackage{tabularx}
\RequirePackage{array}

<<<<<<< HEAD
% Use a clean sans-serif face similar to the reference resume.
=======
>>>>>>> fcdf599 (Update Sun Wei one-page resume layout and content)
\IfFontExistsTF{Microsoft YaHei}
  {\setmainfont{Microsoft YaHei}}
  {\IfFontExistsTF{Noto Sans}{\setmainfont{Noto Sans}}{\setmainfont{TeX Gyre Heros}}}

\RequirePackage[
  a4paper,
<<<<<<< HEAD
  left=0.50in,
  right=0.50in,
  top=0.17in,
  bottom=0.30in,
=======
  left=0.44in,
  right=0.44in,
  top=0.13in,
  bottom=0.18in,
>>>>>>> fcdf599 (Update Sun Wei one-page resume layout and content)
  nohead,
  nofoot
]{geometry}

\pagestyle{empty}
\setlist{leftmargin=1.35em,labelsep=0.45em}
<<<<<<< HEAD
\setlist[itemize]{label=\textbullet,topsep=1.20em,itemsep=0.15em,parsep=0pt,partopsep=0pt}

% Section heading: bold title + thin horizontal rule, matching the reference.
\titleformat{\section}
  {\fontsize{12.3pt}{14.5pt}\selectfont\bfseries\raggedright}
  {}{0em}{\raisebox{0.24em}}
  [\vspace{-0.42em}\titlerule]
\titlespacing*{\section}{0pt}{0.44em}{0.24em}

% A compact one-line heading with a right-aligned date.
\newcommand{\datedline}[2]{%
  \noindent\begin{tabularx}{\linewidth}{@{}X>{\raggedleft\arraybackslash}p{4.85cm}@{}}
    #1 & {\fontsize{9.15pt}{10.4pt}\selectfont\mbox{#2}}
=======
\setlist[itemize]{label=\textbullet,topsep=1.10em,itemsep=0.22em,parsep=0pt,partopsep=0pt}

\definecolor{ResumeSectionBlue}{HTML}{203B70}
\titleformat{\section}
  {\color{ResumeSectionBlue}\fontsize{13.0pt}{15.4pt}\selectfont\bfseries\raggedright}
  {}{0em}{\raisebox{0.24em}}
  [\vspace{-0.38em}\titlerule]
\titlespacing*{\section}{0pt}{0.62em}{0.38em}

\newcommand{\datedline}[2]{%
  \noindent\begin{tabularx}{\linewidth}{@{}X>{\raggedleft\arraybackslash}p{4.85cm}@{}}
    #1 & {\fontsize{9.55pt}{11.1pt}\selectfont\mbox{#2}}
>>>>>>> fcdf599 (Update Sun Wei one-page resume layout and content)
  \end{tabularx}\par%
}

\newcommand{\datedsubsection}[2]{%
<<<<<<< HEAD
  \vspace{0.10em}%
  \datedline{\bfseries #1}{#2}%
  \vspace{0.00em}%
}

\newcommand{\educationline}[4]{%
  \datedline{\textbf{#1}\hspace{0.42em}#2}{#4}%
  \vspace{0.20em}%
  {#3\par}%
  \vspace{0.53em}%
}

% Pale-blue school labels as used in the reference PDF.
=======
  \vspace{0.18em}%
  \datedline{{\fontsize{10.65pt}{12.1pt}\selectfont\bfseries #1}}{#2}%
  \vspace{0.08em}%
}

\newcommand{\educationline}[4]{%
  \datedline{{\fontsize{10.55pt}{12.0pt}\selectfont\textbf{#1}}\hspace{0.42em}#2}{#4}%
  \vspace{0.24em}%
  {#3\par}%
  \vspace{0.70em}%
}

>>>>>>> fcdf599 (Update Sun Wei one-page resume layout and content)
\definecolor{ResumeTagBlue}{RGB}{89,145,242}
\definecolor{ResumeTagBg}{RGB}{231,239,255}
\newcommand{\resumetag}[1]{%
  \begingroup
  \setlength{\fboxsep}{1.2pt}%
  \colorbox{ResumeTagBg}{\textcolor{ResumeTagBlue}{\fontsize{8.6pt}{9.5pt}\selectfont #1}}%
  \endgroup
}

<<<<<<< HEAD
% Detail paragraph with an italic lead-in label.
\newcommand{\detail}[2]{%
  \noindent\textit{#1：}#2\par
  \vspace{0.18em}%
}

\newcommand{\name}[1]{%
  {\fontsize{18.5pt}{21pt}\selectfont\bfseries #1\par}%
  \vspace{0.34em}%
}

\newcommand{\contactInfo}[4]{%
  {\fontsize{10.1pt}{12.0pt}\selectfont
    #1\hspace{0.65em}|\hspace{0.65em}#2%
    \ifthenelse{\isempty{#3}}{}{\hspace{0.65em}|\hspace{0.65em}#3}%
    \ifthenelse{\isempty{#4}}{}{\hspace{0.65em}|\hspace{0.65em}#4}%
    \par}%
=======
\newcommand{\detail}[2]{%
  \noindent\textit{#1：}#2\par
  \vspace{0.28em}%
}

\newlength{\resumeHeaderTextWidth}
\setlength{\resumeHeaderTextWidth}{16.40cm}
\newcommand{\name}[1]{%
  \noindent\makebox[\resumeHeaderTextWidth][c]{%
    \raisebox{-0.80cm}[0pt][0pt]{\fontsize{19.2pt}{22pt}\selectfont\bfseries #1}}%
  \par\vspace{0.38em}%
}

\newcommand{\contactInfo}[4]{%
  \noindent\makebox[\resumeHeaderTextWidth][c]{%
    \fontsize{10.25pt}{12.2pt}\selectfont
    #1\hspace{0.65em}|\hspace{0.65em}#2%
    \ifthenelse{\isempty{#3}}{}{\hspace{0.65em}|\hspace{0.65em}#3}%
    \ifthenelse{\isempty{#4}}{}{\hspace{0.65em}|\hspace{0.65em}#4}%
  }\par%
>>>>>>> fcdf599 (Update Sun Wei one-page resume layout and content)
}

\newlength{\resumePhotoWidth}
\setlength{\resumePhotoWidth}{2.22cm}
\newlength{\resumePhotoX}
\setlength{\resumePhotoX}{\paperwidth}
<<<<<<< HEAD
\addtolength{\resumePhotoX}{-0.50in}
=======
\addtolength{\resumePhotoX}{-0.44in}
>>>>>>> fcdf599 (Update Sun Wei one-page resume layout and content)
\addtolength{\resumePhotoX}{-\resumePhotoWidth}
\newcommand{\photo}[1]{%
  \begin{textblock*}{\resumePhotoWidth}(\resumePhotoX,0.45in)
    \includegraphics[width=\resumePhotoWidth,height=2.62cm]{#1}
  \end{textblock*}%
}

<<<<<<< HEAD
% Subtle geometric header decoration behind the photo, inspired by the reference.
\newcommand{\headerdecor}{%
  \begin{tikzpicture}[remember picture,overlay]
    \begin{scope}[shift={(current page.north east)},xshift=-2.2cm,yshift=-1.0cm,rotate=45]
      \draw[black!11,line width=0.45pt] (-2.0,-1.2) rectangle (0.15,0.95);
      \draw[black!11,line width=0.45pt] (-3.0,-0.1) rectangle (-0.9,2.0);
      \draw[black!11,line width=0.45pt] (-0.9,-2.2) rectangle (1.2,-0.1);
      \draw[black!11,line width=0.45pt] (-4.1,1.0) rectangle (-2.0,3.1);
    \end{scope}
    \begin{scope}[shift={(current page.north west)},xshift=0.15cm,yshift=-1.0cm,rotate=45]
      \draw[black!10,line width=0.45pt] (-0.5,-1.2) rectangle (1.6,0.9);
    \end{scope}
  \end{tikzpicture}%
}

\newcommand{\role}[2]{%
  {\par \textit{#1} ~ #2 \par}%
  \vspace{0.3ex}%
}
=======
\newcommand{\headerdecor}{%
  % Larger geometric header decoration, kept as a light gray page-corner overlay.
  \begin{tikzpicture}[remember picture,overlay]
    \begin{scope}[shift={(current page.north east)},xshift=-0.25cm,yshift=-0.08cm,rotate=45]
      \draw[black!14,line width=0.55pt] (-2.70,-1.70) rectangle (0.20,1.20);
      \draw[black!11,line width=0.50pt] (-4.00,-0.45) rectangle (-1.10,2.45);
      \draw[black!11,line width=0.50pt] (-1.25,-3.05) rectangle (1.65,-0.15);
      \draw[black!9,line width=0.48pt] (-5.30,0.85) rectangle (-2.40,3.75);
    \end{scope}
    \begin{scope}[shift={(current page.north west)},xshift=-0.30cm,yshift=-0.12cm,rotate=45]
      \draw[black!12,line width=0.52pt] (-0.65,-1.55) rectangle (2.25,1.35);
      \draw[black!8,line width=0.45pt] (1.05,-2.95) rectangle (3.95,-0.05);
    \end{scope}
  \end{tikzpicture}%
}
>>>>>>> fcdf599 (Update Sun Wei one-page resume layout and content)
