#requires -Version 5.1
<#
.SYNOPSIS
    Builds and validates the Neon Horizon Synthwave themes for Telegram Desktop (Windows)
    and Telegram Android from common/palette.json and generated wallpapers.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$palettePath = Join-Path $RepoRoot 'common\palette.json'
$androidBasePath = Join-Path $RepoRoot 'common\android_base.json'
$winBgPath = Join-Path $RepoRoot 'windows\background.jpg'
$andBgPath = Join-Path $RepoRoot 'android\background_android.jpg'

foreach ($req in @($palettePath, $androidBasePath, $winBgPath, $andBgPath)) {
    if (-not (Test-Path $req)) {
        throw "Required file not found: $req"
    }
}

$palette = Get-Content -Path $palettePath -Raw -Encoding UTF8 | ConvertFrom-Json
$c = $palette.colors
$peers = $palette.peers

function To-LowerHex6([string]$hex) {
    $h = $hex.Trim().TrimStart('#')
    if ($h.Length -eq 8) { $h = $h.Substring(0, 6) }
    return '#' + $h.ToLowerInvariant()
}

function With-AlphaDesktop([string]$hex6, [string]$alphaHex) {
    # Telegram Desktop uses #RRGGBBAA
    return (To-LowerHex6 $hex6) + $alphaHex.ToLowerInvariant()
}

function To-AndroidHex([string]$hex) {
    # Telegram Android uses #AARRGGBB
    $h = $hex.Trim().TrimStart('#')
    if ($h.Length -eq 6) {
        return ('#ff' + $h.ToLowerInvariant())
    }
    if ($h.Length -eq 8) {
        return ('#' + $h.ToLowerInvariant())
    }
    throw "Invalid hex color: $hex"
}

function DesktopHex-ToAndroidHex([string]$rrggbbaa) {
    $h = $rrggbbaa.Trim().TrimStart('#').ToLowerInvariant()
    if ($h.Length -eq 6) { return '#ff' + $h }
    if ($h.Length -eq 8) { return '#' + $h.Substring(6, 2) + $h.Substring(0, 6) }
    throw "Invalid desktop hex: $rrggbbaa"
}

function Clamp01([double]$v) {
    if ($v -lt 0.0) { return 0.0 }
    if ($v -gt 1.0) { return 1.0 }
    return $v
}

function Rgb-ToHsl([int]$r, [int]$g, [int]$b) {
    $rf = $r / 255.0; $gf = $g / 255.0; $bf = $b / 255.0
    $max = [Math]::Max($rf, [Math]::Max($gf, $bf))
    $min = [Math]::Min($rf, [Math]::Min($gf, $bf))
    $l = ($max + $min) * 0.5
    if ([Math]::Abs($max - $min) -lt 1e-6) {
        return @(0.0, 0.0, $l)
    }
    $d = $max - $min
    $s = if ($l -gt 0.5) { $d / (2.0 - $max - $min) } else { $d / ($max + $min) }
    $h = 0.0
    if ($max -eq $rf) {
        $h = (($gf - $bf) / $d) + $(if ($gf -lt $bf) { 6.0 } else { 0.0 })
    } elseif ($max -eq $gf) {
        $h = (($bf - $rf) / $d) + 2.0
    } else {
        $h = (($rf - $gf) / $d) + 4.0
    }
    $h /= 6.0
    $hDeg = $h * 360.0
    return @($hDeg, $s, $l)
}

function Hue-ToRgb([double]$p, [double]$q, [double]$t) {
    if ($t -lt 0.0) { $t += 1.0 }
    if ($t -gt 1.0) { $t -= 1.0 }
    if ($t -lt (1.0 / 6.0)) { return $p + ($q - $p) * 6.0 * $t }
    if ($t -lt 0.5) { return $q }
    if ($t -lt (2.0 / 3.0)) { return $p + ($q - $p) * (2.0 / 3.0 - $t) * 6.0 }
    return $p
}

function Hsl-ToHex([double]$aByte, [double]$hDeg, [double]$s, [double]$l) {
    $h = (($hDeg % 360.0) + 360.0) % 360.0 / 360.0
    $s = Clamp01 $s
    $l = Clamp01 $l
    if ($s -lt 1e-6) {
        $v = [int][Math]::Round($l * 255.0)
        return ('#{0:x2}{1:x2}{2:x2}{3:x2}' -f [int]$aByte, $v, $v, $v)
    }
    $q = if ($l -lt 0.5) { $l * (1.0 + $s) } else { $l + $s - $l * $s }
    $p = 2.0 * $l - $q
    $r = [int][Math]::Round((Hue-ToRgb $p $q ($h + 1.0 / 3.0)) * 255.0)
    $g = [int][Math]::Round((Hue-ToRgb $p $q $h) * 255.0)
    $b = [int][Math]::Round((Hue-ToRgb $p $q ($h - 1.0 / 3.0)) * 255.0)
    return ('#{0:x2}{1:x2}{2:x2}{3:x2}' -f [int]$aByte, $r, $g, $b)
}

function Transform-ToSynthwaveAndroidHex([string]$argbHex) {
    $h = $argbHex.Trim().TrimStart('#')
    if ($h.Length -ne 8) { return $argbHex }
    $a = [Convert]::ToInt32($h.Substring(0, 2), 16)
    $r = [Convert]::ToInt32($h.Substring(2, 2), 16)
    $g = [Convert]::ToInt32($h.Substring(4, 2), 16)
    $b = [Convert]::ToInt32($h.Substring(6, 2), 16)

    # Preserve pure black/white and nearly pure shadows/white overlays
    if ($r -eq 0 -and $g -eq 0 -and $b -eq 0) {
        return ('#{0:x2}070412' -f $a)
    }
    if ($r -ge 250 -and $g -ge 250 -and $b -ge 250) {
        return ('#{0:x2}f4f7ff' -f $a)
    }

    $hsl = Rgb-ToHsl $r $g $b
    $hue = $hsl[0]; $sat = $hsl[1]; $lit = $hsl[2]

    # Blue / sky-blue Telegram UI accents -> Electric Cyan (184 deg) or Violet-Blue (262 deg)
    if ($hue -ge 185.0 -and $hue -le 240.0 -and $sat -gt 0.25) {
        if ($lit -lt 0.32) {
            # Dark navy surfaces -> deep synthwave violet-indigo (258 deg)
            return (Hsl-ToHex $a 258.0 ([Math]::Max(0.45, $sat * 1.15)) ([Math]::Max(0.05, $lit * 0.88)))
        } elseif ($lit -lt 0.58) {
            # Mid blue controls -> neon cyan-teal
            return (Hsl-ToHex $a 186.0 ([Math]::Min(1.0, $sat * 1.25)) ([Math]::Min(0.56, $lit * 1.05)))
        } else {
            # Bright sky blue links/icons -> glowing neon cyan
            return (Hsl-ToHex $a 185.0 0.96 ([Math]::Min(0.76, $lit)))
        }
    }

    # Neutral / gray dark surfaces & muted gray text -> tinted synthwave lavender/indigo
    if ($sat -lt 0.20) {
        if ($lit -lt 0.28) {
            return (Hsl-ToHex $a 258.0 0.52 ([Math]::Max(0.05, $lit * 0.90)))
        } elseif ($lit -lt 0.65) {
            return (Hsl-ToHex $a 262.0 0.34 ([Math]::Max(0.32, $lit * 1.06)))
        } else {
            return (Hsl-ToHex $a 256.0 0.45 ([Math]::Min(0.95, $lit)))
        }
    }

    # Preserve semantic green/red/orange/purple hues cleanly
    return ('#{0}' -f $h.ToLowerInvariant())
}

# ==============================================================================
# 1. WINDOWS: Telegram Desktop (colors.tdesktop-theme + NeonHorizonSynthwave.tdesktop-theme)
# ==============================================================================
Write-Host 'Building Windows Telegram Desktop theme...'

$p1 = $peers[0]; $p2 = $peers[1]; $p3 = $peers[2]; $p4 = $peers[3]
$p5 = $peers[4]; $p6 = $peers[5]; $p7 = $peers[6]; $p8 = $peers[7]

$desktopColors = @"
// =============================================================================
// Neon Horizon — Synthwave / Outrun 84 Theme for Telegram Desktop (Windows)
// Repository: https://github.com/Roma-Skull/synthwave-telegram-theme
// =============================================================================

// --- Core Window & Text ---
windowBg: $(To-LowerHex6 $c.windowBg); // main window background
windowFg: $(To-LowerHex6 $c.textPrimary); // main text
windowBgOver: $(To-LowerHex6 $c.surfaceElevated); // background with mouse over
windowBgRipple: $(To-LowerHex6 $c.surfaceRipple); // ripple effect
windowFgOver: $(To-LowerHex6 $c.textBright); // text with mouse over
windowSubTextFg: $(To-LowerHex6 $c.textMuted); // additional text
windowSubTextFgOver: $(To-LowerHex6 $c.textSecondary); // additional text with mouse over
windowBoldFg: $(To-LowerHex6 $c.textPrimary); // bold text
windowBoldFgOver: $(To-LowerHex6 $c.textBright); // bold text with mouse over
windowBgActive: $(To-LowerHex6 $c.magenta); // active elements (toggles, checks, badges)
windowFgActive: $(To-LowerHex6 $c.textBright); // text on active areas
windowActiveTextFg: $(To-LowerHex6 $c.cyan); // online / active accent text
windowShadowFg: #04010c; // shadow base
windowShadowFgFallback: $(To-LowerHex6 $c.voidBg); // shadow fallback
shadowFg: #9d3df578; // 1px neon-violet panel dividers & shadows with opacity
slideFadeOutBg: #06021255; // slide transition fade
slideFadeOutShadowFg: windowShadowFg; // slide transition right shadow
imageBg: $(To-LowerHex6 $c.voidBg); // image fallback
imageBgTransparent: $(To-LowerHex6 $c.textBright); // transparent image backdrop

// --- Buttons & Inputs ---
activeButtonBg: $(To-LowerHex6 $c.magenta); // primary button background
activeButtonBgOver: $(To-LowerHex6 $c.magentaBright); // primary button hover
activeButtonBgRipple: $(To-LowerHex6 $c.magentaSoft); // primary button ripple
activeButtonFg: $(To-LowerHex6 $c.textBright); // primary button text
activeButtonFgOver: $(To-LowerHex6 $c.textBright); // primary button text hover
activeButtonSecondaryFg: #ffd1e8; // primary button secondary counter text
activeButtonSecondaryFgOver: activeButtonSecondaryFg; // primary button secondary counter hover
activeLineFg: $(To-LowerHex6 $c.cyan); // active input underline
activeLineFgError: $(To-LowerHex6 $c.red); // error input underline
lightButtonBg: $(To-LowerHex6 $c.windowBg); // secondary/box button background
lightButtonBgOver: $(To-LowerHex6 $c.surfaceElevated); // secondary/box button hover
lightButtonBgRipple: $(To-LowerHex6 $c.surfaceHover); // secondary/box button ripple
lightButtonFg: $(To-LowerHex6 $c.cyan); // secondary/box button text
lightButtonFgOver: $(To-LowerHex6 $c.cyanHover); // secondary/box button text hover
attentionButtonFg: $(To-LowerHex6 $c.red); // destructive button text
attentionButtonFgOver: #ff708d; // destructive button text hover
attentionButtonBgOver: #5c183070; // destructive button hover
attentionButtonBgRipple: #781f3e80; // destructive button ripple
outlineButtonBg: windowBg; // outlined button background
outlineButtonBgOver: $(To-LowerHex6 $c.surfaceElevated); // outlined button hover
outlineButtonOutlineFg: $(To-LowerHex6 $c.violet); // outlined button border
outlineButtonBgRipple: $(To-LowerHex6 $c.surfaceHover); // outlined button ripple

// --- Menus, Scrollbars, Loaders & Sliders ---
menuBg: $(To-LowerHex6 $c.surfaceBg); // popup menu background
menuBgOver: $(To-LowerHex6 $c.surfaceHover); // popup menu item hover
menuBgRipple: $(To-LowerHex6 $c.surfaceRipple); // popup menu item ripple
menuIconFg: $(To-LowerHex6 $c.textSecondary); // popup menu icon
menuIconFgOver: $(To-LowerHex6 $c.cyan); // popup menu icon hover
menuSubmenuArrowFg: $(To-LowerHex6 $c.textMuted); // submenu arrow
menuFgDisabled: $(To-LowerHex6 $c.textDisabled); // disabled menu item text
menuSeparatorFg: $(To-LowerHex6 $c.borderSubtle); // menu separator
scrollBarBg: #b537f266; // scrollbar thumb
scrollBarBgOver: #00f0ff99; // scrollbar thumb hover
scrollBg: #ffffff12; // scrollbar track
scrollBgOver: #ffffff20; // scrollbar track hover
smallCloseIconFg: $(To-LowerHex6 $c.textMuted); // small X icon
smallCloseIconFgOver: $(To-LowerHex6 $c.magentaSoft); // small X icon hover
radialFg: $(To-LowerHex6 $c.cyan); // radial loader
radialBg: #08051388; // radial loader backdrop
placeholderFg: $(To-LowerHex6 $c.textMuted); // input placeholder
placeholderFgActive: $(To-LowerHex6 $c.textSecondary); // focused input placeholder
inputBorderFg: $(To-LowerHex6 $c.borderStrong); // input bottom border
filterInputBorderFg: $(To-LowerHex6 $c.violet); // rounded search border
filterInputInactiveBg: $(To-LowerHex6 $c.surfaceElevated); // search field inactive
checkboxFg: $(To-LowerHex6 $c.textMuted); // unchecked checkbox
sliderBgInactive: $(To-LowerHex6 $c.borderSubtle); // slider inactive track
sliderBgActive: $(To-LowerHex6 $c.cyan); // slider active track
tooltipBg: $(To-LowerHex6 $c.surfaceElevated); // tooltip background
tooltipFg: $(To-LowerHex6 $c.textCyan); // tooltip text
tooltipBorderFg: $(To-LowerHex6 $c.violet); // tooltip border

// --- Window Title Bar (Windows / macOS) ---
titleShadow: #b537f278; // 1px neon-violet line under custom window title
titleBg: $(To-LowerHex6 $c.voidBg); // inactive window title bar
titleBgActive: $(To-LowerHex6 $c.surfaceHeader); // active window title bar
titleButtonBg: titleBg; // caption button inactive
titleButtonFg: $(To-LowerHex6 $c.textMuted); // caption icon inactive
titleButtonBgOver: $(To-LowerHex6 $c.surfaceElevated); // caption button hover (inactive)
titleButtonFgOver: $(To-LowerHex6 $c.cyan); // caption icon hover (inactive)
titleButtonBgActive: $(To-LowerHex6 $c.surfaceHeader); // caption button active
titleButtonFgActive: $(To-LowerHex6 $c.textSecondary); // caption icon active
titleButtonBgActiveOver: $(To-LowerHex6 $c.surfaceHover); // caption button hover (active)
titleButtonFgActiveOver: $(To-LowerHex6 $c.cyan); // caption icon hover (active)
titleButtonCloseBg: titleButtonBg; // close button inactive
titleButtonCloseFg: titleButtonFg; // close icon inactive
titleButtonCloseBgOver: $(To-LowerHex6 $c.magenta); // close button hover (inactive)
titleButtonCloseFgOver: $(To-LowerHex6 $c.textBright); // close icon hover (inactive)
titleButtonCloseBgActive: $(To-LowerHex6 $c.surfaceHeader); // close button active
titleButtonCloseFgActive: titleButtonFgActive; // close icon active
titleButtonCloseBgActiveOver: $(To-LowerHex6 $c.magenta); // close button hover (active)
titleButtonCloseFgActiveOver: $(To-LowerHex6 $c.textBright); // close icon hover (active)
titleFg: $(To-LowerHex6 $c.textMuted); // macOS title inactive
titleFgActive: $(To-LowerHex6 $c.textPrimary); // macOS title active

// --- System Tray & Modal Boxes ---
trayCounterBg: $(To-LowerHex6 $c.magenta); // tray unread badge
trayCounterBgMute: $(To-LowerHex6 $c.textMuted); // tray muted unread badge
trayCounterFg: $(To-LowerHex6 $c.textBright); // tray badge text
trayCounterBgMacInvert: #ffffff; // macOS tray inverted bg
trayCounterFgMacInvert: #ffffff01; // macOS tray inverted text
layerBg: #05020ea6; // modal backdrop dim
cancelIconFg: $(To-LowerHex6 $c.textSecondary); // cancel/close icon
cancelIconFgOver: $(To-LowerHex6 $c.cyan); // cancel/close icon hover
boxBg: $(To-LowerHex6 $c.surfaceBg); // modal dialog background
boxTextFg: windowFg; // modal dialog text
boxTextFgGood: $(To-LowerHex6 $c.cyan); // valid input text
boxTextFgError: $(To-LowerHex6 $c.red); // invalid input text
boxTitleFg: $(To-LowerHex6 $c.textPrimary); // modal title
boxSearchBg: $(To-LowerHex6 $c.surfaceBg); // modal search background
boxTitleAdditionalFg: $(To-LowerHex6 $c.textMuted); // modal subtitle
boxTitleCloseFg: cancelIconFg; // modal close icon
boxTitleCloseFgOver: cancelIconFgOver; // modal close icon hover
membersAboutLimitFg: $(To-LowerHex6 $c.textMuted); // member limit note
contactsBg: $(To-LowerHex6 $c.surfaceBg); // contacts list row
contactsBgOver: $(To-LowerHex6 $c.surfaceElevated); // contacts list row hover
contactsNameFg: boxTextFg; // contact name
contactsStatusFg: $(To-LowerHex6 $c.textMuted); // contact status
contactsStatusFgOver: $(To-LowerHex6 $c.textSecondary); // contact status hover
contactsStatusFgOnline: $(To-LowerHex6 $c.cyan); // contact online status
photoCropFadeBg: layerBg; // avatar crop fade
photoCropPointFg: #00f0ffaa; // avatar crop handles
callArrowFg: $(To-LowerHex6 $c.cyan); // incoming call arrow
callArrowMissedFg: $(To-LowerHex6 $c.red); // missed call arrow

// --- Intro / Login ---
introBg: windowBg; // login background
introTitleFg: $(To-LowerHex6 $c.textPrimary); // login title
introDescriptionFg: $(To-LowerHex6 $c.textSecondary); // login description
introErrorFg: $(To-LowerHex6 $c.red); // login error
introCoverTopBg: #140830; // intro cover gradient top
introCoverBottomBg: #3b1261; // intro cover gradient bottom
introCoverIconsFg: $(To-LowerHex6 $c.violet); // intro cloud graphics
introCoverPlaneTrace: $(To-LowerHex6 $c.cyanMuted); // intro plane traces
introCoverPlaneInner: $(To-LowerHex6 $c.textCyan); // intro plane inner
introCoverPlaneOuter: $(To-LowerHex6 $c.textSecondary); // intro plane outer
introCoverPlaneTop: $(To-LowerHex6 $c.textBright); // intro plane top

// --- Chat List (Dialogs) ---
dialogsMenuIconFg: $(To-LowerHex6 $c.cyanSoft); // main menu hamburger & lock icon
dialogsMenuIconFgOver: $(To-LowerHex6 $c.cyan); // main menu icon hover
dialogsBg: windowBg; // chat list background
dialogsNameFg: $(To-LowerHex6 $c.textPrimary); // chat title
dialogsChatIconFg: $(To-LowerHex6 $c.cyanSoft); // group/channel icon
dialogsDateFg: $(To-LowerHex6 $c.textMuted); // message date
dialogsTextFg: $(To-LowerHex6 $c.textSecondary); // message preview
dialogsTextFgService: $(To-LowerHex6 $c.cyanSoft); // sender / media type preview
dialogsDraftFg: $(To-LowerHex6 $c.magentaSoft); // Draft label
dialogsVerifiedIconBg: $(To-LowerHex6 $c.cyan); // verified badge fill
dialogsVerifiedIconFg: $(To-LowerHex6 $c.voidBg); // verified badge checkmark
dialogsSendingIconFg: $(To-LowerHex6 $c.textMuted); // sending clock
dialogsSentIconFg: $(To-LowerHex6 $c.cyan); // sent / read checkmarks
dialogsUnreadBg: $(To-LowerHex6 $c.magenta); // unread counter fill
dialogsUnreadBgMuted: $(To-LowerHex6 $c.borderStrong); // muted unread counter fill
dialogsUnreadFg: $(To-LowerHex6 $c.textBright); // unread counter text
dialogsBgOver: $(To-LowerHex6 $c.surfaceElevated); // chat row hover
dialogsOnlineBadgeFg: $(To-LowerHex6 $c.cyan); // online dot
dialogsNameFgOver: $(To-LowerHex6 $c.textBright); // chat title hover
dialogsChatIconFgOver: $(To-LowerHex6 $c.cyan); // group icon hover
dialogsDateFgOver: $(To-LowerHex6 $c.textSecondary); // date hover
dialogsTextFgOver: $(To-LowerHex6 $c.textCyan); // preview hover
dialogsTextFgServiceOver: $(To-LowerHex6 $c.cyan); // sender preview hover
dialogsDraftFgOver: dialogsDraftFg; // draft hover
dialogsVerifiedIconBgOver: $(To-LowerHex6 $c.cyanHover); // verified badge hover
dialogsVerifiedIconFgOver: dialogsVerifiedIconFg; // verified check hover
dialogsSendingIconFgOver: dialogsSendingIconFg; // sending clock hover
dialogsSentIconFgOver: $(To-LowerHex6 $c.cyanHover); // sent ticks hover
dialogsUnreadBgOver: $(To-LowerHex6 $c.magentaBright); // unread badge hover
dialogsUnreadBgMutedOver: #5f2ea8; // muted unread badge hover
dialogsUnreadFgOver: dialogsUnreadFg; // unread text hover
dialogsBgActive: $(To-LowerHex6 $c.surfaceActive); // active chat row
dialogsNameFgActive: $(To-LowerHex6 $c.textBright); // active chat title
dialogsChatIconFgActive: $(To-LowerHex6 $c.cyan); // active group icon
dialogsDateFgActive: $(To-LowerHex6 $c.cyanSoft); // active chat date
dialogsTextFgActive: $(To-LowerHex6 $c.textCyan); // active chat preview
dialogsTextFgServiceActive: $(To-LowerHex6 $c.cyan); // active chat sender
dialogsDraftFgActive: $(To-LowerHex6 $c.amber); // active chat draft
dialogsVerifiedIconBgActive: $(To-LowerHex6 $c.cyan); // active chat verified fill
dialogsVerifiedIconFgActive: $(To-LowerHex6 $c.voidBg); // active chat verified check
dialogsSendingIconFgActive: #ffffffb0; // active chat sending clock
dialogsSentIconFgActive: $(To-LowerHex6 $c.cyan); // active chat sent ticks
dialogsUnreadBgActive: $(To-LowerHex6 $c.textBright); // active chat unread fill
dialogsUnreadBgMutedActive: #8b5fd4; // active chat muted unread fill
dialogsUnreadFgActive: $(To-LowerHex6 $c.surfaceActive); // active chat unread text
dialogsOnlineBadgeFgActive: $(To-LowerHex6 $c.cyan); // active chat online dot
dialogsRippleBg: $(To-LowerHex6 $c.surfaceHover); // chat row ripple
dialogsRippleBgActive: $(To-LowerHex6 $c.surfaceRipple); // active chat row ripple
dialogsForwardBg: dialogsBgActive; // compact forward panel bg
dialogsForwardFg: dialogsNameFgActive; // compact forward panel text
searchedBarBg: $(To-LowerHex6 $c.surfaceElevated); // search section bar bg
searchedBarFg: $(To-LowerHex6 $c.cyanSoft); // search section bar text

// --- Top Bar & Emoji / Stickers Panel ---
topBarBg: $(To-LowerHex6 $c.surfaceHeader); // chat header bar
emojiPanBg: $(To-LowerHex6 $c.surfaceBg); // emoji panel background
emojiPanCategories: $(To-LowerHex6 $c.voidBg); // emoji category bar
emojiPanHeaderFg: $(To-LowerHex6 $c.cyanSoft); // emoji section header text
emojiPanHeaderBg: #140b29eb; // emoji section header bg
stickerPanDeleteBg: #080513cc; // delete sticker X bg
stickerPanDeleteFg: windowFgActive; // delete sticker X icon
stickerPreviewBg: #080513c8; // sticker preview overlay

// --- Chat History & Bubbles ---
historyTextInFg: $(To-LowerHex6 $c.textPrimary); // incoming message text
historyTextInFgSelected: $(To-LowerHex6 $c.textBright); // incoming selected text
historyTextOutFg: $(To-LowerHex6 $c.textPrimary); // outgoing message text
historyTextOutFgSelected: $(To-LowerHex6 $c.textBright); // outgoing selected text
historyLinkInFg: $(To-LowerHex6 $c.cyanSoft); // incoming link
historyLinkInFgSelected: $(To-LowerHex6 $c.cyanHover); // incoming selected link
historyLinkOutFg: $(To-LowerHex6 $c.cyan); // outgoing link
historyLinkOutFgSelected: $(To-LowerHex6 $c.cyanHover); // outgoing selected link
historyFileNameInFg: historyTextInFg; // incoming filename
historyFileNameInFgSelected: $(To-LowerHex6 $c.textBright); // incoming selected filename
historyFileNameOutFg: historyTextOutFg; // outgoing filename
historyFileNameOutFgSelected: $(To-LowerHex6 $c.textBright); // outgoing selected filename
historyOutIconFg: $(To-LowerHex6 $c.cyan); // outgoing ticks
historyOutIconFgSelected: $(To-LowerHex6 $c.textBright); // outgoing selected ticks
historyIconFgInverted: #ffffffeb; // inverted ticks on media
historySendingOutIconFg: $(To-LowerHex6 $c.magentaSoft); // outgoing sending clock
historySendingInIconFg: $(To-LowerHex6 $c.textMuted); // incoming sending clock
historySendingInvertedIconFg: #ffffffcc; // media sending clock
historyCallArrowInFg: $(To-LowerHex6 $c.cyan); // incoming call arrow
historyCallArrowInFgSelected: $(To-LowerHex6 $c.textBright); // incoming selected call arrow
historyCallArrowMissedInFg: callArrowMissedFg; // missed call arrow
historyCallArrowMissedInFgSelected: $(To-LowerHex6 $c.textBright); // missed selected call arrow
historyCallArrowOutFg: $(To-LowerHex6 $c.magentaSoft); // outgoing call arrow
historyCallArrowOutFgSelected: $(To-LowerHex6 $c.textBright); // outgoing selected call arrow
historyUnreadBarBg: $(To-LowerHex6 $c.surfaceElevated); // unread messages divider
historyUnreadBarBorder: #b537f244; // unread divider border
historyUnreadBarFg: $(To-LowerHex6 $c.cyan); // unread divider text
historyForwardChooseBg: #08051366; // forward recipient overlay
historyForwardChooseFg: windowFgActive; // forward recipient text

// --- Peer Colors (8 Synthwave Slots) ---
historyPeer1NameFg: $(To-LowerHex6 $p1.name); // slot 1 name
historyPeer1NameFgSelected: #ffffff;
historyPeer1UserpicBg: $(To-LowerHex6 $p1.avatar1);
historyPeer2NameFg: $(To-LowerHex6 $p2.name); // slot 2 name
historyPeer2NameFgSelected: #ffffff;
historyPeer2UserpicBg: $(To-LowerHex6 $p2.avatar1);
historyPeer3NameFg: $(To-LowerHex6 $p3.name); // slot 3 name
historyPeer3NameFgSelected: #ffffff;
historyPeer3UserpicBg: $(To-LowerHex6 $p3.avatar1);
historyPeer4NameFg: $(To-LowerHex6 $p4.name); // slot 4 name
historyPeer4NameFgSelected: #ffffff;
historyPeer4UserpicBg: $(To-LowerHex6 $p4.avatar1);
historyPeer5NameFg: $(To-LowerHex6 $p5.name); // slot 5 name
historyPeer5NameFgSelected: #ffffff;
historyPeer5UserpicBg: $(To-LowerHex6 $p5.avatar1);
historyPeer6NameFg: $(To-LowerHex6 $p6.name); // slot 6 name
historyPeer6NameFgSelected: #ffffff;
historyPeer6UserpicBg: $(To-LowerHex6 $p6.avatar1);
historyPeer7NameFg: $(To-LowerHex6 $p7.name); // slot 7 name
historyPeer7NameFgSelected: #ffffff;
historyPeer7UserpicBg: $(To-LowerHex6 $p7.avatar1);
historyPeer8NameFg: $(To-LowerHex6 $p8.name); // slot 8 name
historyPeer8NameFgSelected: #ffffff;
historyPeer8UserpicBg: $(To-LowerHex6 $p8.avatar1);
historyPeerUserpicFg: windowFgActive; // initials on userpic
historyPeer1UserpicBg2: $(To-LowerHex6 $p1.avatar2);
historyPeer2UserpicBg2: $(To-LowerHex6 $p2.avatar2);
historyPeer3UserpicBg2: $(To-LowerHex6 $p3.avatar2);
historyPeer4UserpicBg2: $(To-LowerHex6 $p4.avatar2);
historyPeer5UserpicBg2: $(To-LowerHex6 $p5.avatar2);
historyPeer6UserpicBg2: $(To-LowerHex6 $p6.avatar2);
historyPeer7UserpicBg2: $(To-LowerHex6 $p7.avatar2);
historyPeer8UserpicBg2: $(To-LowerHex6 $p8.avatar2);
historyPeerSavedMessagesBg2: historyPeer4UserpicBg2;

// --- History Scrollbar & Message Bubbles ---
historyScrollBarBg: #b537f27a;
historyScrollBarBgOver: #00f0ffb8;
historyScrollBg: #1b0f3860;
historyScrollBgOver: #2d185690;
msgInBg: $(To-LowerHex6 $c.msgInBg); // incoming bubble
msgInBgSelected: $(To-LowerHex6 $c.msgInBgSelected); // incoming bubble selected
msgOutBg: $(To-LowerHex6 $c.msgOutBg); // outgoing bubble
msgOutBgSelected: $(To-LowerHex6 $c.msgOutBgSelected); // outgoing bubble selected
msgSelectOverlay: #00f0ff33; // selected media overlay
msgStickerOverlay: #ff2a8555; // selected sticker overlay
msgInServiceFg: $(To-LowerHex6 $c.cyanSoft); // incoming forward header
msgInServiceFgSelected: #ffffff;
msgOutServiceFg: $(To-LowerHex6 $c.magentaSoft); // outgoing forward header
msgOutServiceFgSelected: #ffffff;
msgInShadow: #00f0ffaa; // electric cyan 1-2px neon underlight below incoming bubbles
msgInShadowSelected: #00f0ffeb;
msgOutShadow: #ff2a85b8; // hot magenta 1-2px neon underlight below outgoing bubbles
msgOutShadowSelected: #ff2a85f0;
msgInDateFg: $(To-LowerHex6 $c.msgInDate); // incoming timestamp
msgInDateFgSelected: #ffffff;
msgOutDateFg: $(To-LowerHex6 $c.msgOutDate); // outgoing timestamp
msgOutDateFgSelected: #ffffff;
msgServiceFg: $(To-LowerHex6 $c.textPrimary); // date pill / service text
msgServiceBg: #140a2bd8; // date pill / bot keyboard button bg
msgServiceBgSelected: #321863e6; // selected service pill
msgInReplyBarColor: $(To-LowerHex6 $c.violet); // incoming reply bar
msgInReplyBarSelColor: #ffffff;
msgOutReplyBarColor: $(To-LowerHex6 $c.cyan); // outgoing reply bar
msgOutReplyBarSelColor: #ffffff;
msgImgReplyBarColor: $(To-LowerHex6 $c.cyan); // media reply bar
msgInMonoFg: #ff79c6; // incoming monospace/code
msgOutMonoFg: #8be9fd; // outgoing monospace/code
msgInMonoFgSelected: #ffd6f0;
msgOutMonoFgSelected: #d6fbff;
msgDateImgFg: #fffffff2; // time on media
msgDateImgBg: #08051380; // time pill on media
msgDateImgBgOver: #140a2ba8; // media download circle hover
msgDateImgBgSelected: #3b176699; // selected media time pill
msgFileThumbLinkInFg: $(To-LowerHex6 $c.cyan);
msgFileThumbLinkInFgSelected: #ffffff;
msgFileThumbLinkOutFg: $(To-LowerHex6 $c.cyanSoft);
msgFileThumbLinkOutFgSelected: #ffffff;
msgFileInBg: $(To-LowerHex6 $c.magenta);
msgFileInBgOver: $(To-LowerHex6 $c.magentaBright);
msgFileInBgSelected: $(To-LowerHex6 $c.cyan);
msgFileOutBg: $(To-LowerHex6 $c.cyanMuted);
msgFileOutBgOver: $(To-LowerHex6 $c.cyan);
msgFileOutBgSelected: $(To-LowerHex6 $c.magenta);
msgFile1Bg: #1f7ae0;
msgFile1BgDark: #1558a8;
msgFile1BgOver: #00b8d4;
msgFile1BgSelected: #ffffff;
msgFile2Bg: #24c997;
msgFile2BgDark: #189670;
msgFile2BgOver: #147a5b;
msgFile2BgSelected: #147a5b;
msgFile3Bg: #ff3b6b;
msgFile3BgDark: #cc234e;
msgFile3BgOver: #a8193d;
msgFile3BgSelected: #a8193d;
msgFile4Bg: #ff9f43;
msgFile4BgDark: #d97c24;
msgFile4BgOver: #b86216;
msgFile4BgSelected: #b86216;
historyFileInIconFg: #ffffff;
historyFileInIconFgSelected: #ffffff;
historyFileInRadialFg: #ffffff;
historyFileInRadialFgSelected: historyFileInIconFgSelected;
historyFileOutIconFg: #ffffff;
historyFileOutIconFgSelected: #ffffff;
historyFileOutRadialFg: #ffffff;
historyFileOutRadialFgSelected: #ffffff;
historyFileThumbIconFg: #f2f8ff;
historyFileThumbIconFgSelected: #ffffff;
historyFileThumbRadialFg: $(To-LowerHex6 $c.cyan);
historyFileThumbRadialFgSelected: #ffffff;
historyVideoMessageProgressFg: $(To-LowerHex6 $c.cyan);
msgWaveformInActive: $(To-LowerHex6 $c.magenta);
msgWaveformInActiveSelected: #ffffff;
msgWaveformInInactive: #4a2a75;
msgWaveformInInactiveSelected: $(To-LowerHex6 $c.magentaSoft);
msgWaveformOutActive: $(To-LowerHex6 $c.cyan);
msgWaveformOutActiveSelected: #ffffff;
msgWaveformOutInactive: #5a3891;
msgWaveformOutInactiveSelected: $(To-LowerHex6 $c.cyanSoft);
msgBotKbOverBgAdd: #00f0ff1a;
msgBotKbIconFg: $(To-LowerHex6 $c.cyan);
msgBotKbRippleBg: #ff2a8522;
mediaInFg: msgInDateFg;
mediaInFgSelected: msgInDateFgSelected;
mediaOutFg: msgOutDateFg;
mediaOutFgSelected: msgOutDateFgSelected;
youtubePlayIconBg: #ff2a85d8;
youtubePlayIconFg: windowFgActive;
videoPlayIconBg: #08051399;
videoPlayIconFg: $(To-LowerHex6 $c.cyan);
toastBg: #140a2be0;
toastFg: windowFgActive;
reportSpamBg: $(To-LowerHex6 $c.surfaceElevated);
reportSpamFg: windowFg;
historyToDownBg: $(To-LowerHex6 $c.surfaceElevated);
historyToDownBgOver: $(To-LowerHex6 $c.surfaceHover);
historyToDownBgRipple: $(To-LowerHex6 $c.surfaceRipple);
historyToDownFg: $(To-LowerHex6 $c.cyanSoft);
historyToDownFgOver: $(To-LowerHex6 $c.cyan);
historyToDownShadow: #04010c70;

// --- Compose Area & Pinned / Reply Panels ---
historyComposeAreaBg: $(To-LowerHex6 $c.surfaceBg);
historyComposeAreaFg: historyTextInFg;
historyComposeAreaFgService: $(To-LowerHex6 $c.textMuted);
historyComposeIconFg: $(To-LowerHex6 $c.textSecondary);
historyComposeIconFgOver: $(To-LowerHex6 $c.cyan);
historySendIconFg: $(To-LowerHex6 $c.cyan);
historySendIconFgOver: $(To-LowerHex6 $c.magenta);
historyPinnedBg: $(To-LowerHex6 $c.surfaceHeader);
historyReplyBg: historyComposeAreaBg;
historyReplyIconFg: $(To-LowerHex6 $c.magenta);
historyReplyCancelFg: cancelIconFg;
historyReplyCancelFgOver: cancelIconFgOver;
historyComposeButtonBg: historyComposeAreaBg;
historyComposeButtonBgOver: $(To-LowerHex6 $c.surfaceElevated);
historyComposeButtonBgRipple: $(To-LowerHex6 $c.surfaceHover);

// --- Shared Media & Profile ---
overviewCheckBg: #08051366;
overviewCheckFg: #ffffff;
overviewCheckFgActive: #ffffff;
overviewPhotoSelectOverlay: #00f0ff33;
profileStatusFgOver: $(To-LowerHex6 $c.textSecondary);
profileVerifiedCheckBg: $(To-LowerHex6 $c.cyan);
profileVerifiedCheckFg: $(To-LowerHex6 $c.voidBg);
profileAdminStartFg: $(To-LowerHex6 $c.amber);
notificationsBoxMonitorFg: windowFg;
notificationsBoxScreenBg: dialogsBgActive;
notificationSampleUserpicFg: $(To-LowerHex6 $c.cyan);
notificationSampleCloseFg: $(To-LowerHex6 $c.textSecondary);
notificationSampleTextFg: $(To-LowerHex6 $c.textPrimary);
notificationSampleNameFg: $(To-LowerHex6 $c.magentaSoft);
changePhoneSimcardFrom: notificationSampleTextFg;
changePhoneSimcardTo: notificationSampleNameFg;

// --- Main Menu Drawer & Media Player ---
mainMenuBg: windowBg;
mainMenuCoverBg: #2b1154;
mainMenuCoverFg: windowFgActive;
mainMenuCloudFg: activeButtonFg;
mainMenuCloudBg: #ff2a85;
mediaPlayerBg: $(To-LowerHex6 $c.surfaceBg);
mediaPlayerActiveFg: $(To-LowerHex6 $c.cyan);
mediaPlayerInactiveFg: sliderBgInactive;
mediaPlayerDisabledFg: #4a2a75;

// --- Media Viewer ---
mediaviewFileBg: windowBg;
mediaviewFileNameFg: windowFg;
mediaviewFileSizeFg: windowSubTextFg;
mediaviewFileRedCornerFg: $(To-LowerHex6 $c.red);
mediaviewFileYellowCornerFg: $(To-LowerHex6 $c.amber);
mediaviewFileGreenCornerFg: $(To-LowerHex6 $c.green);
mediaviewFileBlueCornerFg: $(To-LowerHex6 $c.cyan);
mediaviewFileExtFg: activeButtonFg;
mediaviewMenuBg: $(To-LowerHex6 $c.surfaceElevated);
mediaviewMenuBgOver: $(To-LowerHex6 $c.surfaceHover);
mediaviewMenuBgRipple: $(To-LowerHex6 $c.surfaceRipple);
mediaviewMenuFg: windowFgActive;
mediaviewBg: #080513f0;
mediaviewVideoBg: imageBg;
mediaviewControlBg: #0e092066;
mediaviewControlFg: windowFgActive;
mediaviewCaptionBg: #0b071899;
mediaviewCaptionFg: mediaviewControlFg;
mediaviewTextLinkFg: $(To-LowerHex6 $c.cyan);
mediaviewSaveMsgBg: toastBg;
mediaviewSaveMsgFg: toastFg;
mediaviewPlaybackActive: $(To-LowerHex6 $c.cyan);
mediaviewPlaybackInactive: #2d1856;
mediaviewPlaybackActiveOver: #ffffff;
mediaviewPlaybackInactiveOver: #4a228a;
mediaviewPlaybackProgressFg: #ffffffd0;
mediaviewPlaybackIconFg: mediaviewPlaybackActive;
mediaviewPlaybackIconFgOver: mediaviewPlaybackActiveOver;
mediaviewTransparentBg: #ffffff;
mediaviewTransparentFg: #b8a4de;
notificationBg: $(To-LowerHex6 $c.surfaceBg);

// --- Calls ---
callBg: #0b0718f5;
callNameFg: #ffffff;
callFingerprintBg: #1b0f3899;
callStatusFg: $(To-LowerHex6 $c.textSecondary);
callIconFg: #ffffff;
callAnswerBg: $(To-LowerHex6 $c.green);
callAnswerRipple: #28c996;
callAnswerBgOuter: #3cf2b830;
callHangupBg: $(To-LowerHex6 $c.red);
callHangupRipple: #d9365c;
callCancelBg: $(To-LowerHex6 $c.surfaceElevated);
callCancelFg: $(To-LowerHex6 $c.textPrimary);
callCancelRipple: $(To-LowerHex6 $c.surfaceHover);
callMuteRipple: #ffffff18;
callBarBg: #2b1454;
callBarMuteRipple: #431f82;
callBarBgMuted: #1d1038;
callBarUnmuteRipple: #2e1859;
callBarFg: dialogsNameFgActive;

// --- Tooltips, Search Inputs, Bot Keyboard & Emoji Icons ---
importantTooltipBg: toastBg;
importantTooltipFg: toastFg;
importantTooltipFgLink: $(To-LowerHex6 $c.cyan);
filterInputActiveBg: $(To-LowerHex6 $c.surfaceHover);
botKbBg: $(To-LowerHex6 $c.surfaceElevated);
botKbDownBg: $(To-LowerHex6 $c.surfaceRipple);
emojiIconFg: $(To-LowerHex6 $c.textMuted);
emojiIconFgActive: $(To-LowerHex6 $c.cyan);
overviewCheckBorder: $(To-LowerHex6 $c.textCyan);

// --- Folders Sidebar (Left Navigation Rail) ---
sideBarBg: $(To-LowerHex6 $c.surfaceSidebar);
sideBarBgActive: $(To-LowerHex6 $c.surfaceHover);
sideBarBgRipple: $(To-LowerHex6 $c.surfaceElevated);
sideBarTextFg: $(To-LowerHex6 $c.textMuted);
sideBarTextFgActive: $(To-LowerHex6 $c.cyan);
sideBarIconFg: $(To-LowerHex6 $c.textMuted);
sideBarIconFgActive: $(To-LowerHex6 $c.cyan);
sideBarBadgeBg: $(To-LowerHex6 $c.magenta);
sideBarBadgeBgMuted: $(To-LowerHex6 $c.borderStrong);

// --- Statistics Charts ---
statisticsChartInactive: #2d1856c8;
statisticsChartActive: #00f0ffd8;
"@

$winColorsPath = Join-Path $RepoRoot 'windows\colors.tdesktop-theme'
[System.IO.File]::WriteAllText($winColorsPath, ($desktopColors -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

$winThemePath = Join-Path $RepoRoot 'windows\NeonHorizonSynthwave.tdesktop-theme'
if (Test-Path $winThemePath) { Remove-Item $winThemePath -Force }
$zip = [System.IO.Compression.ZipFile]::Open($winThemePath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $winColorsPath, 'colors.tdesktop-theme', [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $winBgPath, 'background.jpg', [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
} finally {
    $zip.Dispose()
}

# ==============================================================================
# 2. ANDROID: Telegram Android (.attheme with embedded wallpaper & no-bg variant)
# ==============================================================================
Write-Host 'Building Android Telegram theme (.attheme)...'

$androidBaseObj = Get-Content -Path $androidBasePath -Raw -Encoding UTF8 | ConvertFrom-Json
$andMap = [ordered]@{}

# Step 2a: Transform all 554 baseline dark keys into Synthwave palette
foreach ($prop in $androidBaseObj.PSObject.Properties) {
    $k = $prop.Name
    $v = [string]$prop.Value
    if ($k -eq 'wallpaperFileOffset') { continue }
    if ($k -eq 'chat_compact_backgroundGradient') {
        $andMap[$k] = '0'
        continue
    }
    if ($v -match '^#[0-9A-Fa-f]{8}$') {
        $andMap[$k] = Transform-ToSynthwaveAndroidHex $v
    } else {
        $andMap[$k] = $v
    }
}

# Step 2b: Apply explicit curated Synthwave tokens across all Android UI surfaces & components
$void = To-AndroidHex $c.voidBg
$deep = To-AndroidHex $c.deepBg
$winBg = To-AndroidHex $c.windowBg
$surf = To-AndroidHex $c.surfaceBg
$elev = To-AndroidHex $c.surfaceElevated
$hover = To-AndroidHex $c.surfaceHover
$ripple = To-AndroidHex $c.surfaceRipple
$actRow = To-AndroidHex $c.surfaceActive
$hdr = To-AndroidHex $c.surfaceHeader
$side = To-AndroidHex $c.surfaceSidebar
$brd = To-AndroidHex $c.borderSubtle
$brdStrong = To-AndroidHex $c.borderStrong

$txtPri = To-AndroidHex $c.textPrimary
$txtBrt = To-AndroidHex $c.textBright
$txtSec = To-AndroidHex $c.textSecondary
$txtMut = To-AndroidHex $c.textMuted
$txtDis = To-AndroidHex $c.textDisabled
$txtCyn = To-AndroidHex $c.textCyan

$cyan = To-AndroidHex $c.cyan
$cyanSoft = To-AndroidHex $c.cyanSoft
$cyanHover = To-AndroidHex $c.cyanHover
$cyanMuted = To-AndroidHex $c.cyanMuted

$mag = To-AndroidHex $c.magenta
$magSoft = To-AndroidHex $c.magentaSoft
$magBright = To-AndroidHex $c.magentaBright

$violet = To-AndroidHex $c.violet
$violetSoft = To-AndroidHex $c.violetSoft
$amber = To-AndroidHex $c.amber
$orange = To-AndroidHex $c.orange
$green = To-AndroidHex $c.green
$red = To-AndroidHex $c.red

$inBub = To-AndroidHex $c.msgInBg
$inBubSel = To-AndroidHex $c.msgInBgSelected
$outBub = To-AndroidHex $c.msgOutBg
$outGrad1 = To-AndroidHex $c.msgOutBgGrad1
$outGrad2 = To-AndroidHex $c.msgOutBgGrad2
$outBubSel = To-AndroidHex $c.msgOutBgSelected

$overrides = [ordered]@{
    # Core Windows & Surfaces
    windowBackgroundWhite = $winBg
    windowBackgroundGray = $void
    windowBackgroundGrayShadow = '#ff04010c'
    windowBackgroundUnchecked = $elev
    windowBackgroundChecked = $mag
    windowBackgroundCheckText = $txtBrt
    windowBackgroundWhiteBlackText = $txtPri
    windowBackgroundWhiteGrayText = $txtMut
    windowBackgroundWhiteGrayText2 = $txtSec
    windowBackgroundWhiteGrayText3 = $txtMut
    windowBackgroundWhiteGrayText4 = '#c88370ad'
    windowBackgroundWhiteGrayText5 = $txtMut
    windowBackgroundWhiteGrayText6 = $txtMut
    windowBackgroundWhiteGrayText7 = $txtSec
    windowBackgroundWhiteGrayText8 = $txtMut
    windowBackgroundWhiteGrayIcon = $txtSec
    windowBackgroundWhiteBlueHeader = $cyan
    windowBackgroundWhiteBlueText = $cyan
    windowBackgroundWhiteBlueText2 = $cyanSoft
    windowBackgroundWhiteBlueText3 = $cyanSoft
    windowBackgroundWhiteBlueText4 = $cyan
    windowBackgroundWhiteBlueText5 = $cyanSoft
    windowBackgroundWhiteBlueText6 = $cyan
    windowBackgroundWhiteBlueText7 = $cyanSoft
    windowBackgroundWhiteBlueButton = $mag
    windowBackgroundWhiteBlueIcon = $cyan
    windowBackgroundWhiteLinkText = $cyan
    windowBackgroundWhiteLinkSelection = '#3300f0ff'
    windowBackgroundWhiteValueText = $cyanSoft
    windowBackgroundWhiteHintText = $txtMut
    windowBackgroundWhiteInputField = $brdStrong
    windowBackgroundWhiteInputFieldActivated = $cyan
    windowBackgroundWhiteGreenText = $green
    windowBackgroundWhiteGreenText2 = $green
    text_RedRegular = $red
    text_RedBold = $red
    fill_RedNormal = $red
    fill_RedDark = '#ff8f1d3d'
    divider = '#ff381c6e'
    graySection = $surf
    key_graySectionText = $cyanSoft
    emptyListPlaceholder = $txtMut
    progressCircle = $cyan
    listSelectorSDK21 = '#2400f0ff'

    # Telegram Brand Accents
    telegram_color = $mag
    telegram_color_text = $cyan
    telegram_color_dialogsLogo = $cyan

    # Action Bar & Tabs
    actionBarDefault = $hdr
    actionBarDefaultSelector = '#2400f0ff'
    actionBarWhiteSelector = '#22ffffff'
    actionBarDefaultIcon = $txtPri
    actionBarDefaultTitle = $txtPri
    actionBarDefaultSubtitle = $cyanSoft
    actionBarDefaultSearch = $txtPri
    actionBarDefaultSearchPlaceholder = '#88b8a4de'
    actionBarDefaultSearchArchivedPlaceholder = '#88b8a4de'
    actionBarDefaultSubmenuBackground = $elev
    actionBarDefaultSubmenuSeparator = $brd
    actionBarDefaultSubmenuItem = $txtPri
    actionBarDefaultSubmenuItemIcon = $cyanSoft
    actionBarDefaultArchived = $elev
    actionBarDefaultArchivedSelector = '#24ff2a85'
    actionBarDefaultArchivedIcon = $txtPri
    actionBarDefaultArchivedTitle = $txtPri
    actionBarDefaultArchivedSearch = $txtPri
    actionBarActionModeDefault = $surf
    actionBarActionModeDefaultTop = $void
    actionBarActionModeDefaultIcon = $cyan
    actionBarActionModeDefaultSelector = '#2600f0ff'
    actionBarActionModeReaction = '#24ff2a85'
    actionBarActionModeReactionText = $txtBrt
    actionBarActionModeReactionDot = $mag
    actionBarTabActiveText = $cyan
    actionBarTabUnactiveText = $txtMut
    actionBarTabLine = $cyan
    actionBarTabSelector = '#2200f0ff'
    actionBarBrowser = $hdr

    # Dialogs / Bottom Sheets / Modals
    dialogBackground = $surf
    dialogBackgroundGray = $winBg
    dialogTopBackground = $elev
    dialogTextBlack = $txtPri
    dialogTextLink = $cyan
    dialogLinkSelection = '#3300f0ff'
    dialogTextBlue = $cyan
    dialogTextBlue2 = $cyanSoft
    dialogTextBlue4 = $cyan
    dialogTextGray = $txtSec
    dialogTextGray2 = $txtMut
    dialogTextGray3 = $txtMut
    dialogTextGray4 = $txtDis
    dialogTextHint = $txtMut
    dialogIcon = $cyanSoft
    dialogGrayLine = $brd
    dialogShadowLine = '#4004010c'
    dialogCardShadow = '#6004010c'
    dialogScrollGlow = '#33b537f2'
    dialogInputField = $brdStrong
    dialogInputFieldActivated = $cyan
    dialogCheckboxSquareBackground = $mag
    dialogCheckboxSquareCheck = $txtBrt
    dialogCheckboxSquareUnchecked = $txtMut
    dialogCheckboxSquareDisabled = $txtDis
    dialogRadioBackground = $txtMut
    dialogRadioBackgroundChecked = $cyan
    dialogRoundCheckBox = $mag
    dialogRoundCheckBoxCheck = $txtBrt
    dialogLineProgress = $cyan
    dialogLineProgressBackground = $brd
    dialogButton = $cyan
    dialogButtonSelector = '#2200f0ff'
    dialog_inlineProgressBackground = $elev
    dialog_inlineProgress = $cyan
    dialogSearchBackground = $elev
    dialogSearchHint = $txtMut
    dialogSearchIcon = $cyanSoft
    dialogSearchText = $txtPri
    dialogFloatingButton = $mag
    dialogFloatingButtonPressed = '#22ffffff'
    dialogFloatingIcon = $txtBrt
    dialogEmptyImage = $txtMut
    dialogEmptyText = $txtMut
    dialogSwipeRemove = $red
    dialogReactionMentionBackground = $mag
    dialogGiftsBackground = $elev
    dialogGiftsTabText = $txtSec

    # Switches & Checkboxes
    switchTrack = '#ff432a70'
    switchTrackChecked = $mag
    switchTrackBlue = '#ff432a70'
    switchTrackBlueChecked = $cyan
    switchTrackBlueThumb = $winBg
    switchTrackBlueThumbChecked = $mag
    switchTrackBlueSelector = '#2200f0ff'
    switchTrackBlueSelectorChecked = '#33ff2a85'
    switch2Track = '#ff432a70'
    switch2TrackChecked = $mag
    checkbox = $mag
    checkboxDisabled = $txtDis
    checkboxCheck = $txtBrt
    checkboxSquareBackground = $mag
    checkboxSquareCheck = $txtBrt
    checkboxSquareUnchecked = $txtMut
    checkboxSquareDisabled = $txtDis
    radioBackground = $txtMut
    radioBackgroundChecked = $cyan

    # Chat List (Dialogs Screen)
    chats_name = $txtPri
    chats_nameArchived = $txtSec
    chats_nameMessage = $txtCyn
    chats_nameMessage_threeLines = $txtCyn
    chats_nameMessageArchived = $txtMut
    chats_nameMessageArchived_threeLines = $txtMut
    chats_message = $txtSec
    chats_message_threeLines = $txtSec
    chats_messageArchived = $txtMut
    chats_date = $txtMut
    chats_date_bold = $txtSec
    chats_draft = $magSoft
    chats_sentCheck = $cyan
    chats_sentReadCheck = $cyan
    chats_sentClock = $txtMut
    chats_sentError = $red
    chats_sentErrorIcon = $txtBrt
    chats_verifiedBackground = $cyan
    chats_verifiedCheck = $void
    chats_muteIcon = $txtMut
    chats_pinnedIcon = $violetSoft
    chats_pinnedOverlay = '#12b537f2'
    chats_tabletSelectedOverlay = '#1aff2a85'
    chats_unreadCounter = $mag
    chats_unreadCounterMuted = $brdStrong
    chats_unreadCounterText = $txtBrt
    chats_secretName = $green
    chats_secretIcon = $green
    chats_onlineCircle = $cyan
    chats_mentionIcon = $txtBrt
    chats_archiveIcon = $txtBrt
    chats_archiveText = $txtBrt
    chats_archiveBackground = $violet
    chats_archivePinBackground = $elev
    chats_archivePullDownBackground = $elev
    chats_archivePullDownBackgroundActive = $mag
    chats_tabUnreadActiveBackground = $cyan
    chats_tabUnreadUnactiveBackground = $brdStrong
    chats_actionBackground = $mag
    chats_actionPressedBackground = $magBright
    chats_actionIcon = $txtBrt
    chats_menuBackground = $winBg
    chats_menuTopBackground = $hdr
    chats_menuTopShadow = '#3004010c'
    chats_menuTopShadowCats = '#3004010c'
    chats_menuName = $txtPri
    chats_menuPhone = '#d0b8a4de'
    chats_menuPhoneCats = $cyanSoft
    chats_menuItemText = $txtPri
    chats_menuItemIcon = $cyanSoft
    chats_menuItemCheck = $cyan

    # Chat Bubbles & Text
    chat_compact_background = $surf
    chat_inBubble = $inBub
    chat_inBubbleSelected = $inBubSel
    chat_inBubbleSelectedOverlay = '#2400f0ff'
    chat_inBubbleShadow = '#7700f0ff'
    chat_outBubble = $outBub
    chat_outBubbleGradient = $outGrad1
    chat_outBubbleGradient2 = $outGrad2
    chat_outBubbleGradient3 = $outBub
    chat_outBubbleGradientAnimated = '0'
    chat_outBubbleSelected = $outBubSel
    chat_outBubbleSelectedOverlay = '#24ff2a85'
    chat_outBubbleGradientSelectedOverlay = '#22ffffff'
    chat_outBubbleShadow = '#85ff2a85'
    chat_inBubbleLocationPlaceholder = '#2a2d1856'
    chat_outBubbleLocationPlaceholder = '#2a4a228a'

    chat_messageTextIn = $txtPri
    chat_messageTextOut = $txtBrt
    chat_messageLinkIn = $cyanSoft
    chat_messageLinkOut = $cyan
    chat_inTextSelectionHighlight = '#4400f0ff'
    chat_outTextSelectionHighlight = '#44ff2a85'
    chat_outTextSelectionCursor = $cyan
    chat_linkSelectBackground = '#3300f0ff'
    chat_outLinkSelectBackground = '#3300f0ff'
    chat_inTimeText = $(To-AndroidHex $c.msgInDate)
    chat_inTimeSelectedText = $txtBrt
    chat_outTimeText = $(To-AndroidHex $c.msgOutDate)
    chat_outTimeSelectedText = $txtBrt
    chat_inViews = $(To-AndroidHex $c.msgInDate)
    chat_inViewsSelected = $txtBrt
    chat_outViews = $(To-AndroidHex $c.msgOutDate)
    chat_outViewsSelected = $txtBrt
    chat_outSentCheck = $cyan
    chat_outSentCheckSelected = $txtBrt
    chat_outSentCheckRead = $cyan
    chat_outSentCheckReadSelected = $txtBrt
    chat_outSentClock = $magSoft
    chat_outSentClockSelected = $txtBrt
    chat_inSentClock = $txtMut
    chat_inSentClockSelected = $txtBrt
    chat_mediaSentCheck = $txtBrt
    chat_mediaSentClock = $txtBrt
    chat_mediaViews = $txtBrt
    chat_mediaTimeText = $txtBrt
    chat_mediaTimeBackground = '#88080513'
    chat_mediaInfoText = $txtBrt
    chat_mediaProgress = $cyan
    chat_mediaLoaderPhoto = '#88080513'
    chat_mediaLoaderPhotoSelected = '#aa2b1454'
    chat_mediaLoaderPhotoIcon = $cyan
    chat_mediaLoaderPhotoIconSelected = $txtBrt
    chat_sentError = $red
    chat_sentErrorIcon = $txtBrt

    # Reply, Quote, Forward, Admin & Code inside Chat
    chat_inReplyLine = $violet
    chat_inReplyNameText = $cyanSoft
    chat_inReplyMessageText = $txtPri
    chat_inReplyMediaMessageText = $txtSec
    chat_inReplyMediaMessageSelectedText = $txtBrt
    chat_outReplyLine = $cyan
    chat_outReplyLine2 = $magSoft
    chat_outReplyNameText = $cyan
    chat_outReplyMessageText = $txtBrt
    chat_outReplyMediaMessageText = $txtCyn
    chat_outReplyMediaMessageSelectedText = $txtBrt
    chat_inForwardedNameText = $cyanSoft
    chat_outForwardedNameText = $magSoft
    chat_inQuote = $violetSoft
    chat_outQuote = $cyan
    chat_inViaBotNameText = $cyanSoft
    chat_outViaBotNameText = $cyan
    chat_inContactNameText = $cyanSoft
    chat_outContactNameText = $cyan
    chat_inContactPhoneText = $txtSec
    chat_outContactPhoneText = $txtCyn
    chat_inContactBackground = $mag
    chat_outContactBackground = $cyanMuted
    chat_inContactIcon = $txtBrt
    chat_outContactIcon = $txtBrt
    chat_inSiteNameText = $cyanSoft
    chat_outSiteNameText = $cyan
    chat_inPreviewLine = $violet
    chat_outPreviewLine = $cyan
    chat_adminText = $amber
    chat_adminSelectedText = $txtBrt
    chat_outAdminText = $amber
    chat_outAdminSelectedText = $txtBrt
    chat_inPsaNameText = $cyan
    chat_outPsaNameText = $cyan
    chat_tagAdmin = '#33b537f2'
    chat_tagCreator = '#33ff2a85'
    chat_inCodeBackground = '#2400f0ff'
    chat_outCodeBackground = '#24ff2a85'
    chat_inArticleCodeBackground = '#ff100824'
    chat_outArticleCodeBackground = '#ff190c36'
    chat_inArticleCodeScrollbarBackground = $brd
    chat_inArticleCodeScrollbar = $violet
    chat_outArticleCodeScrollbarBackground = $brd
    chat_outArticleCodeScrollbar = $cyan
    chat_inTableBackground = '#ff1b1038'
    chat_outTableBackground = '#ff311657'
    chat_inTableBorder = $brdStrong
    chat_outTableBorder = '#ff6330b5'
    chat_inDivider = $brd
    chat_outDivider = '#4400f0ff'

    # Service Pills & Blur
    chat_serviceBackground = '#d8140a2b'
    chat_serviceBackgroundSelected = '#e6321863'
    chat_serviceBackgroundSelector = '#2400f0ff'
    chat_serviceText = $txtPri
    chat_serviceLink = $cyan
    chat_serviceIcon = $cyan
    chat_BlurAlpha = '#c40e0920'
    chat_BlurAlphaSlow = '#d60e0920'

    # Waveforms, Files & Audio
    chat_inVoiceSeekbar = $brdStrong
    chat_inVoiceSeekbarFill = $mag
    chat_inVoiceSeekbarSelected = $magSoft
    chat_outVoiceSeekbar = '#ff5a3891'
    chat_outVoiceSeekbarFill = $cyan
    chat_outVoiceSeekbarSelected = $cyanHover
    chat_inAudioSeekbar = $brdStrong
    chat_inAudioSeekbarFill = $mag
    chat_inAudioSeekbarSelected = $magSoft
    chat_inAudioCacheSeekbar = '#44b537f2'
    chat_outAudioSeekbar = '#ff5a3891'
    chat_outAudioSeekbarFill = $cyan
    chat_outAudioSeekbarSelected = $cyanHover
    chat_outAudioCacheSeekbar = '#4400f0ff'
    chat_inAudioProgress = $mag
    chat_inAudioSelectedProgress = $txtBrt
    chat_outAudioProgress = $cyan
    chat_outAudioSelectedProgress = $txtBrt
    chat_inAudioTitleText = $txtPri
    chat_outAudioTitleText = $txtBrt
    chat_inAudioPerfomerText = $txtSec
    chat_inAudioPerfomerSelectedText = $txtBrt
    chat_outAudioPerfomerText = $txtCyn
    chat_outAudioPerfomerSelectedText = $txtBrt
    chat_inAudioDurationText = $txtMut
    chat_inAudioDurationSelectedText = $txtBrt
    chat_outAudioDurationText = $txtCyn
    chat_outAudioDurationSelectedText = $txtBrt
    chat_inFileBackground = $mag
    chat_inFileBackgroundSelected = $cyan
    chat_outFileBackground = $cyanMuted
    chat_outFileBackgroundSelected = $mag
    chat_inFileProgress = $txtBrt
    chat_inFileProgressSelected = $txtBrt
    chat_outFileProgress = $txtBrt
    chat_outFileProgressSelected = $txtBrt
    chat_inFileNameText = $txtPri
    chat_outFileNameText = $txtBrt
    chat_inFileInfoText = $txtSec
    chat_inFileInfoSelectedText = $txtBrt
    chat_outFileInfoText = $txtCyn
    chat_outFileInfoSelectedText = $txtBrt
    chat_inLoader = $mag
    chat_inLoaderSelected = $cyan
    chat_outLoader = $cyan
    chat_outLoaderSelected = $mag
    chat_inLoaderPhoto = '#ff221144'
    chat_inArticleDetailsArrow = $cyanSoft
    chat_inArticleDetailsLine = $brdStrong
    chat_outArticleDetailsArrow = $cyan
    chat_outArticleDetailsLine = '#ff6330b5'

    # Compose Panel, Top Panel, Emoji & Stickers
    chat_messagePanelBackground = $surf
    chat_messagePanelShadow = '#5504010c'
    chat_messagePanelText = $txtPri
    chat_messagePanelHint = '#998370ad'
    chat_messagePanelCursor = $cyan
    chat_messagePanelIcons = $txtSec
    chat_messagePanelSend = $cyan
    chat_messagePanelVoiceBackground = $mag
    chat_messagePanelVoicePressed = $txtBrt
    key_chat_messagePanelVoiceLock = $txtBrt
    key_chat_messagePanelVoiceLockBackground = $elev
    key_chat_messagePanelVoiceLockShadow = '#4004010c'
    chat_messagePanelVoiceDelete = $txtBrt
    chat_messagePanelVoiceDuration = $txtBrt
    chat_messagePanelCancelInlineBot = $magSoft
    chat_recordTime = $txtPri
    chat_recordVoiceCancel = $magSoft
    chat_recordedVoicePlayPause = $txtBrt
    chat_recordedVoiceProgress = $cyan
    chat_recordedVoiceProgressInner = $txtBrt
    chat_recordedVoiceDarkerBackground = $elev
    chat_topPanelBackground = $hdr
    chat_topPanelClose = $txtSec
    chat_topPanelLine = $cyan
    chat_topPanelMessage = $txtSec
    chat_topPanelTitle = $cyanSoft
    chat_replyPanelClose = $txtSec
    chat_replyPanelIcons = $cyan
    chat_replyPanelLine = $brd
    chat_replyPanelName = $cyanSoft
    chat_searchPanelIcons = $cyanSoft
    chat_searchPanelText = $txtPri
    chat_goDownButton = $elev
    chat_goDownButtonCounter = $txtBrt
    chat_goDownButtonCounterBackground = $mag
    chat_unreadMessagesStartBackground = $elev
    chat_unreadMessagesStartText = $cyan
    chat_unreadMessagesStartArrowIcon = $cyan
    chat_status = $cyanSoft
    chat_emojiPanelBackground = $surf
    chat_emojiPanelShadowLine = $brd
    chat_emojiPanelEmptyText = $txtMut
    chat_emojiPanelIcon = $txtMut
    chat_emojiPanelIconSelected = $cyan
    chat_emojiBottomPanelIcon = $txtMut
    chat_emojiPanelBackspace = $magSoft
    chat_emojiPanelStickerPackSelector = '#2400f0ff'
    chat_emojiPanelStickerPackSelectorLine = $cyan
    chat_emojiPanelStickerSetName = $txtSec
    chat_emojiPanelStickerSetNameHighlight = $cyan
    chat_emojiPanelStickerSetNameIcon = $txtMut
    chat_emojiPanelTrendingTitle = $txtPri
    chat_emojiPanelNewTrending = $mag
    chat_emojiSearchBackground = $elev
    chat_stickersHintPanel = $elev
    chat_gifSaveHintText = $txtPri
    chat_gifSaveHintBackground = '#e61b0f38'
    chat_botButtonText = $txtPri
    chat_botKeyboardButtonText = $txtPri
    chat_botKeyboardButtonBackground = $elev
    chat_botKeyboardButtonBackgroundPressed = $hover
    chat_attachCheckBoxCheck = $txtBrt
    chat_attachCheckBoxBackground = $mag
    chat_attachPhotoBackground = '#1a00f0ff'
    chat_attachGalleryBackground = $violet
    chat_attachAudioBackground = $mag
    chat_attachLocationBackground = $cyanMuted
    chat_attachIcon = $txtBrt
    chat_attachContactText = $amber
    chat_attachEmptyImage = $txtMut
    chat_attachPermissionImage = $txtSec
    chat_attachPermissionText = $txtSec
    chat_attachPermissionMark = $red
    chat_inPollCorrectAnswer = $green
    chat_outPollCorrectAnswer = $green
    chat_inPollWrongAnswer = $red
    chat_outPollWrongAnswer = $red
    chat_editMediaButton = $cyan

    # Reactions & IV Buttons
    chat_inReactionButtonBackground = '#28b537f2'
    chat_inReactionButtonText = $txtPri
    chat_inReactionButtonTextSelected = $txtBrt
    chat_outReactionButtonBackground = '#2800f0ff'
    chat_outReactionButtonText = $txtBrt
    chat_outReactionButtonTextSelected = $txtBrt
    chat_reactionServiceButtonBackgroundSelected = $mag
    chat_reactionServiceButtonTextSelected = $txtBrt
    chat_msgIvButtonDefaultIn = $elev
    chat_msgIvButtonDefaultInPressed = $hover
    chat_msgIvButtonDefaultInText = $txtPri
    chat_msgIvButtonPrimaryIn = $mag
    chat_msgIvButtonPrimaryInPressed = $magBright
    chat_msgIvButtonPrimaryInText = $txtBrt
    chat_msgIvButtonDangerIn = '#ff4a1236'
    chat_msgIvButtonDangerInPressed = '#ff6b184c'
    chat_msgIvButtonDangerInText = '#ffff7a96'
    chat_msgIvButtonSuccessIn = '#ff113830'
    chat_msgIvButtonSuccessInPressed = '#ff184f44'
    chat_msgIvButtonSuccessInText = $green
    chat_msgIvButtonDefaultInlineIn = '#2200f0ff'
    chat_msgIvButtonDefaultInlineInPressed = '#3800f0ff'
    chat_msgIvButtonDefaultInlineInText = $cyan
    chat_msgIvButtonDefaultOut = $hover
    chat_msgIvButtonDefaultOutPressed = $ripple
    chat_msgIvButtonDefaultOutText = $txtBrt
    chat_msgIvButtonPrimaryOut = $cyanMuted
    chat_msgIvButtonPrimaryOutPressed = $cyan
    chat_msgIvButtonPrimaryOutText = $txtBrt
    chat_msgIvButtonDangerOut = '#ff4a1236'
    chat_msgIvButtonDangerOutPressed = '#ff6b184c'
    chat_msgIvButtonDangerOutText = '#ffff7a96'
    chat_msgIvButtonSuccessOut = '#ff113830'
    chat_msgIvButtonSuccessOutPressed = '#ff184f44'
    chat_msgIvButtonSuccessOutText = $green
    chat_msgIvButtonDefaultInlineOut = '#2200f0ff'
    chat_msgIvButtonDefaultInlineOutPressed = '#3800f0ff'
    chat_msgIvButtonDefaultInlineOutText = $cyan
    botKeyboard_button_primary = $mag
    botKeyboard_button_danger = $red
    botKeyboard_button_success = $green

    # Profile, Player, Glass UI & Stories
    profile_title = $txtPri
    profile_status = $cyanSoft
    profile_actionIcon = $txtBrt
    profile_actionBackground = $mag
    profile_actionPressedBackground = $magBright
    profile_verifiedBackground = $cyan
    profile_verifiedCheck = $void
    profile_tabText = $txtMut
    profile_tabSelectedText = $cyan
    profile_tabSelectedLine = $cyan
    profile_tabSelector = '#2200f0ff'
    inappPlayerBackground = $hdr
    inappPlayerTitle = $txtPri
    inappPlayerPerformer = $cyanSoft
    inappPlayerPlayPause = $cyan
    inappPlayerClose = $txtSec
    player_actionBarSelector = '#2200f0ff'
    player_actionBarTitle = $txtPri
    player_actionBarSubtitle = $cyanSoft
    player_actionBarItems = $txtPri
    player_background = $surf
    player_button = $txtPri
    player_buttonActive = $cyan
    player_progress = $cyan
    player_progressBackground = $brdStrong
    player_time = $txtMut
    glass_defaultIcon = '#b0f2f8ff'
    glass_defaultText = '#b0f2f8ff'
    glass_targetMainTabs = $hdr
    glass_targetMainTopPanel = $hdr
    glass_tabSelected = '#2a00f0ff'
    glass_tabSelectedText = $cyan
    glass_tabUnselected = $txtMut

    # Stories Rings & Premium / Stars Accents
    stories_circle1 = $cyan
    stories_circle2 = $mag
    stories_circle_dialog1 = $cyan
    stories_circle_dialog2 = $mag
    stories_circle_closeFriends1 = $green
    stories_circle_closeFriends2 = $cyan
    stories_circle_live1 = $mag
    stories_circle_live2 = $amber
    premiumGradient0 = $cyan
    premiumGradient1 = $violet
    premiumGradient2 = $mag
    premiumGradient3 = $amber
    premiumGradient4 = $cyan
    premiumGradientBackground1 = $elev
    premiumGradientBackground2 = $surf
    premiumGradientBackground3 = $void
    premiumGradientBackground4 = $deep
    premiumGradientBackgroundOverlay = '#22b537f2'
    premiumStarGradient1 = $cyan
    premiumStarGradient2 = $mag
    premiumStartSmallStarsColor = $cyanSoft
    premiumStartSmallStarsColor2 = $magSoft
    premiumCoinGradient1 = $amber
    premiumCoinGradient2 = $orange
    premiumGradientBottomSheet1 = $elev
    premiumGradientBottomSheet2 = $surf
    premiumGradientBottomSheet3 = $void

    # Avatars & Peer Names (8 Synthwave Slots)
    avatar_text = $txtBrt
    avatar_backgroundActionBarBlue = $hdr
    avatar_actionBarIconBlue = $txtPri
    avatar_actionBarSelectorBlue = '#2200f0ff'
    avatar_backgroundArchived = $elev
    avatar_backgroundSaved = $cyanMuted
    avatar_backgroundRed = $(To-AndroidHex $p1.avatar1)
    avatar_background2Red = $(To-AndroidHex $p1.avatar2)
    avatar_nameInMessageRed = $(To-AndroidHex $p1.name)
    avatar_backgroundGreen = $(To-AndroidHex $p2.avatar1)
    avatar_background2Green = $(To-AndroidHex $p2.avatar2)
    avatar_nameInMessageGreen = $(To-AndroidHex $p2.name)
    avatar_backgroundOrange = $(To-AndroidHex $p3.avatar1)
    avatar_background2Orange = $(To-AndroidHex $p3.avatar2)
    avatar_nameInMessageOrange = $(To-AndroidHex $p3.name)
    avatar_backgroundBlue = $(To-AndroidHex $p4.avatar1)
    avatar_background2Blue = $(To-AndroidHex $p4.avatar2)
    avatar_nameInMessageBlue = $(To-AndroidHex $p4.name)
    avatar_backgroundViolet = $(To-AndroidHex $p5.avatar1)
    avatar_background2Violet = $(To-AndroidHex $p5.avatar2)
    avatar_nameInMessageViolet = $(To-AndroidHex $p5.name)
    avatar_backgroundPink = $(To-AndroidHex $p6.avatar1)
    avatar_background2Pink = $(To-AndroidHex $p6.avatar2)
    avatar_nameInMessagePink = $(To-AndroidHex $p6.name)
    avatar_backgroundCyan = $(To-AndroidHex $p7.avatar1)
    avatar_background2Cyan = $(To-AndroidHex $p7.avatar2)
    avatar_nameInMessageCyan = $(To-AndroidHex $p7.name)

    # Code Syntax Highlighting
    code_keyword = $magSoft
    code_function = $cyan
    code_constant = $amber
    code_string = $green
    code_number = $violetSoft
    code_operator = $txtCyn
    code_comment = $txtMut

    # Compact / Group Voice / Fast Scroll / Topics / Stickers
    fastScrollActive = $mag
    fastScrollInactive = $brdStrong
    fastScrollText = $txtBrt
    topics_unreadCounter = $mag
    topics_unreadCounterMuted = $brdStrong
    featuredStickers_addButton = $mag
    featuredStickers_addButton2 = $violet
    featuredStickers_addButtonPressed = $magBright
    featuredStickers_buttonText = $txtBrt
    featuredStickers_buttonProgress = $txtBrt
    featuredStickers_removeButtonText = $cyan
    featuredStickers_unread = $cyan
    returnToCallBackground = $violet
    returnToCallMutedBackground = $elev
    returnToCallText = $txtBrt
    voipgroup_actionBar = $void
    voipgroup_actionBarUnscrolled = $hdr
    voipgroup_listViewBackground = $winBg
    voipgroup_listViewBackgroundUnscrolled = $surf
    voipgroup_dialogBackground = $surf
    voipgroup_inviteMembersBackground = $elev
    voipgroup_listeningText = $cyan
    voipgroup_speakingText = $green
    voipgroup_checkMenu = $cyan
    voipgroup_soundButton = '#7d25144b'
    voipgroup_soundButtonActive = '#7d00c4d6'
    voipgroup_soundButtonActiveScrolled = '#8200f0ff'
    voipgroup_muteButton = $green
    voipgroup_unmuteButton = $mag
    voipgroup_disabledButton = $elev
    voipgroup_disabledButtonActive = $hover
    statisticChartLine_purple = $violet
    statisticChartLine_cyan = $cyan
    statisticChartLineEmpty = $brd
    statisticChartActiveLine = $cyan
    statisticChartActivePickerChart = '#d8ff2a85'
    statisticChartBackZoomColor = $cyan
    statisticChartChevronColor = $txtSec
    statisticChartHintLine = '#28b537f2'
    color_cyan = $cyan
    reactionStarSelector = '#33ffe85f'
    buttonNeutral = $elev
    buttonNeutralText = $cyan
    sharedMedia_photoPlaceholder = $elev
}

foreach ($k in $overrides.Keys) {
    $andMap[$k] = $overrides[$k]
}

# Build text payload with strict Unix LF line endings
$lines = New-Object System.Collections.Generic.List[string]
foreach ($k in $andMap.Keys) {
    # Skip wallpaper solid/gradient overrides for embedded-wallpaper build
    if ($k -in @('chat_wallpaper', 'chat_wallpaper_gradient_to', 'chat_wallpaper_gradient_to1', 'key_chat_wallpaper_gradient_to2', 'key_chat_wallpaper_gradient_to3', 'chat_wallpaper_gradient_rotation', 'wallpaperFileOffset')) {
        continue
    }
    $lines.Add("$k=$($andMap[$k])")
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$headerBytes = $utf8NoBom.GetBytes(($lines -join "`n") + "`nWPS`n")
$jpgBytes = [System.IO.File]::ReadAllBytes($andBgPath)
$footerBytes = $utf8NoBom.GetBytes("`nWPE`n")

$andThemePath = Join-Path $RepoRoot 'android\NeonHorizonSynthwave.attheme'
$fs = [System.IO.File]::Open($andThemePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
try {
    $fs.Write($headerBytes, 0, $headerBytes.Length)
    $fs.Write($jpgBytes, 0, $jpgBytes.Length)
    $fs.Write($footerBytes, 0, $footerBytes.Length)
} finally {
    $fs.Dispose()
}

# Also generate a lightweight no-background gradient variant
$noBgLines = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
    $noBgLines.Add($line)
}
$noBgLines.Add("chat_wallpaper=$deep")
$noBgLines.Add("chat_wallpaper_gradient_to=#ff1d0c3d")
$noBgLines.Add("key_chat_wallpaper_gradient_to2=#ff381259")
$noBgLines.Add("key_chat_wallpaper_gradient_to3=#ff100826")
$noBgLines.Add("chat_wallpaper_gradient_rotation=45")
$noBgLines.Add("wallpaperFileOffset=-1")

$andNoBgPath = Join-Path $RepoRoot 'android\NeonHorizonSynthwave-no-bg.attheme'
[System.IO.File]::WriteAllBytes($andNoBgPath, $utf8NoBom.GetBytes(($noBgLines -join "`n") + "`n"))

# ==============================================================================
# 3. VALIDATION CHECKS (Desktop ZIP + Android Theme.java Parser Simulation)
# ==============================================================================
Write-Host 'Validating generated themes...'

# Validate Windows .tdesktop-theme ZIP structure & color syntax
$checkZip = [System.IO.Compression.ZipFile]::OpenRead($winThemePath)
try {
    $entryNames = @($checkZip.Entries | ForEach-Object { $_.FullName })
    if ($entryNames -notcontains 'colors.tdesktop-theme' -or $entryNames -notcontains 'background.jpg') {
        throw "Invalid .tdesktop-theme archive contents: $($entryNames -join ', ')"
    }
} finally {
    $checkZip.Dispose()
}
$winColorLines = Get-Content -Path $winColorsPath -Encoding UTF8 | Where-Object { $_ -match '^[a-zA-Z0-9_]+:' }
Write-Host "  [OK] Windows colors.tdesktop-theme keys: $($winColorLines.Count)"
foreach ($wLine in $winColorLines) {
    if ($wLine -notmatch '^[a-zA-Z0-9_]+:\s*(#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?|[a-zA-Z0-9_]+);') {
        throw "Invalid tdesktop color syntax: $wLine"
    }
}

# Validate Android .attheme simulating DrKLO/Telegram Theme.java getThemeFileValues
$rawAnd = [System.IO.File]::ReadAllBytes($andThemePath)
$wpsBytes = [System.Text.Encoding]::ASCII.GetBytes("`nWPS`n")
$wpsPos = -1
for ($i = 0; $i -le $rawAnd.Length - $wpsBytes.Length; $i++) {
    $match = $true
    for ($j = 0; $j -lt $wpsBytes.Length; $j++) {
        if ($rawAnd[$i + $j] -ne $wpsBytes[$j]) { $match = $false; break }
    }
    if ($match) { $wpsPos = $i; break }
}
if ($wpsPos -lt 0) { throw 'Android .attheme missing WPS marker!' }

$headerText = $utf8NoBom.GetString($rawAnd, 0, $wpsPos)
if ($headerText.Contains("`r")) { throw 'Android .attheme header contains CR (\r), must be LF (\n) only!' }
$parsedHeaderLines = $headerText -split "`n"
foreach ($hl in $parsedHeaderLines) {
    if ($hl -notmatch '^[a-zA-Z0-9_]+=(#[0-9a-fA-F]{8}|-?\d+)$') {
        throw "Invalid Android .attheme line: $hl"
    }
}
$wpOffset = $wpsPos + $wpsBytes.Length
if ($rawAnd[$wpOffset] -ne 0xFF -or $rawAnd[$wpOffset + 1] -ne 0xD8 -or $rawAnd[$wpOffset + 2] -ne 0xFF) {
    throw 'Embedded JPEG SOI magic bytes (FF D8 FF) not found at wallpaperFileOffset!'
}
Write-Host "  [OK] Android NeonHorizonSynthwave.attheme keys: $($parsedHeaderLines.Count), wallpaperFileOffset: $wpOffset, size: $($rawAnd.Length) bytes"
Write-Host "  [OK] Android NeonHorizonSynthwave-no-bg.attheme keys: $($noBgLines.Count)"
