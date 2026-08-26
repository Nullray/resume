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

% Use a clean sans-serif face similar to the reference resume.
\IfFontExistsTF{Microsoft YaHei}
  {\setmainfont{Microsoft YaHei}}
  {\IfFontExistsTF{Noto Sans}{\setmainfont{Noto Sans}}{\setmainfont{TeX Gyre Heros}}}

\RequirePackage[
  a4paper,
  left=0.50in,
  right=0.50in,
  top=0.17in,
  bottom=0.30in,
  nohead,
  nofoot
]{geometry}

\pagestyle{empty}
\setlist{leftmargin=1.35em,labelsep=0.45em}
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
  \end{tabularx}\par%
}

\newcommand{\datedsubsection}[2]{%
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
\definecolor{ResumeTagBlue}{RGB}{89,145,242}
\definecolor{ResumeTagBg}{RGB}{231,239,255}
\newcommand{\resumetag}[1]{%
  \begingroup
  \setlength{\fboxsep}{1.2pt}%
  \colorbox{ResumeTagBg}{\textcolor{ResumeTagBlue}{\fontsize{8.6pt}{9.5pt}\selectfont #1}}%
  \endgroup
}

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
}

\newlength{\resumePhotoWidth}
\setlength{\resumePhotoWidth}{2.22cm}
\newlength{\resumePhotoX}
\setlength{\resumePhotoX}{\paperwidth}
\addtolength{\resumePhotoX}{-0.50in}
\addtolength{\resumePhotoX}{-\resumePhotoWidth}
\newcommand{\photo}[1]{%
  \begin{textblock*}{\resumePhotoWidth}(\resumePhotoX,0.45in)
    \includegraphics[width=\resumePhotoWidth,height=2.62cm]{#1}
  \end{textblock*}%
}

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
