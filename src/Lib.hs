module Lib (Msg (..), initModel, app) where

import Brick (App (..), AttrMap, BrickEvent, EventM, Next, Widget)
import qualified Brick as B
import qualified Brick.Markup as BM
import qualified Brick.Types as BT
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text.Markup (Markup, (@@))
import qualified Data.Text.Markup as M
import Errors (
    Error (..),
    FileErrorGroup (..),
    FormattedTextOptions (..),
    Message,
    MessageFragment (..),
 )
import qualified Errors
import qualified Graphics.Vty as V
import qualified Graphics.Vty.Attributes as VA
import qualified Graphics.Vty.Attributes.Color as VAC
import qualified List
import qualified Maybe
import NriPrelude
import System.Exit (ExitCode (ExitSuccess))
import Prelude (Either (..), String, return)


data Model = Model
    { mStatus :: Status
    , mLog :: List String
    }


data Status
    = AllGood
    | Compiling (Maybe String)
    | Errors
        (List FileErrorGroup)
        (Set String) -- expanded files:
        (Set (String, Int)) -- expanded errors: (path,index of error)
    | CouldntParseElmMakeOutput String


initModel :: Model
initModel =
    Model
        { mStatus = AllGood
        , mLog = []
        }


data Name
    = File String
    | ErrorAt String Int
    | AppViewport
    deriving (Show, Ord, Eq)


data Msg
    = RecompileStarted (Maybe String)
    | GotElmMakeOutput (ExitCode, String, String)
    deriving (Show)


app :: App Model Msg Name
app =
    App
        { appDraw = draw
        , appChooseCursor = B.showFirstCursor
        , appHandleEvent = handleEvent
        , appStartEvent = return
        , appAttrMap = attributeMap
        }


------ DRAW

draw :: Model -> List (Widget Name)
draw model =
    let widget =
            case mStatus model of
                AllGood -> drawAllGood
                Compiling triggerFile -> drawCompiling triggerFile
                Errors errors expandedFiles expandedErrors ->
                    drawErrors errors expandedFiles expandedErrors
                CouldntParseElmMakeOutput jsonError -> drawJsonError jsonError
     in [B.viewport AppViewport B.Vertical widget]


drawAllGood :: Widget Name
drawAllGood = B.withAttr (B.attrName "good") <| B.str "All good!"


drawCompiling :: Maybe String -> Widget Name
drawCompiling triggerFile =
    case triggerFile of
        Nothing -> B.str "Compiling"
        Just file ->
            B.hBox
                [ B.str "Compiling (triggered by: "
                , B.withAttr (B.attrName "path") <| B.str file
                , B.str ")"
                ]


drawJsonError :: String -> Widget Name
drawJsonError err =
    B.strWrap err


drawErrors :: List FileErrorGroup -> Set String -> Set (String, Int) -> Widget Name
drawErrors files expandedFiles expandedErrors =
    files
        |> List.map (drawErrorsForFile expandedFiles expandedErrors)
        |> B.vBox


drawErrorsForFile :: Set String -> Set (String, Int) -> FileErrorGroup -> Widget Name
drawErrorsForFile expandedFiles expandedErrors file =
    let path = fPath file
        errors = fErrors file
        isExpanded = Set.member path expandedFiles

        button :: String
        button = if isExpanded then "(-) " else "(+) "
     in ( B.hBox
            [ (B.clickable (File path) <| B.withAttr (B.attrName "path") <| B.str button)
            , (B.clickable (File path) <| B.withAttr (B.attrName "path") <| B.str path)
            ] :
          if isExpanded
            then
                List.indexedMap (drawError path expandedErrors) errors
                    ++ [B.str " "]
            else []
        )
            |> B.vBox


drawError :: String -> Set (String, Int) -> Int -> Error -> Widget Name
drawError path expandedErrors i err =
    if isExpanded
        then drawExpandedError path i err
        else drawCollapsedError path i err
  where
    isExpanded = Set.member (path, i) expandedErrors


drawExpandedError :: String -> Int -> Error -> Widget Name
drawExpandedError path i err =
    B.hBox
        [ B.clickable (ErrorAt path i) <| B.str "[-] "
        , B.vBox
            [ B.clickable (ErrorAt path i) <| B.str <| eTitle err
            , B.str " "
            , drawMessage <| eMessage err
            , B.str " "
            ]
        ]


drawMessage :: Message -> Widget Name
drawMessage fragments =
    fragments
        |> Errors.normalizeFragments
        |> List.map drawLine
        |> B.vBox


drawLine :: List MessageFragment -> Widget Name
drawLine fragments =
    fragments
        |> List.map drawFragment
        |> B.hBox


drawFragment :: MessageFragment -> Widget Name
drawFragment fragment =
    let markup :: Markup VA.Attr
        markup =
            case fragment of
                RawText text ->
                    M.fromText <| T.pack text
                FormattedText opts ->
                    let attr =
                            VA.defAttr
                                `VA.withStyle` (if fBold opts then VA.bold else VA.defaultStyleMask)
                                `VA.withStyle` (if fUnderline opts then VA.underline else VA.defaultStyleMask)
                                `VA.withForeColor` (Maybe.withDefault VAC.red (color (fColor opts)))
                     in (T.pack <| fString opts) @@ attr
                Newline ->
                    M.fromText "\n "
     in BM.markup markup


color :: Maybe String -> Maybe VAC.Color
color string =
    case string of
        Just "red" -> Just VAC.red
        Just "RED" -> Just VAC.brightRed
        Just "magenta" -> Just VAC.magenta
        Just "MAGENTA" -> Just VAC.brightMagenta
        Just "yellow" -> Just VAC.yellow
        Just "YELLOW" -> Just VAC.brightYellow
        Just "green" -> Just VAC.green
        Just "GREEN" -> Just VAC.brightGreen
        Just "cyan" -> Just VAC.cyan
        Just "CYAN" -> Just VAC.brightCyan
        Just "blue" -> Just VAC.blue
        Just "BLUE" -> Just VAC.brightBlue
        Just "black" -> Just VAC.black
        Just "BLACK" -> Just VAC.brightBlack
        Just "white" -> Just VAC.white
        Just "WHITE" -> Just VAC.brightWhite
        _ -> Nothing


drawCollapsedError :: String -> Int -> Error -> Widget Name
drawCollapsedError path i err =
    B.hBox
        [ B.clickable (ErrorAt path i) <| B.str "[+] "
        , B.clickable (ErrorAt path i) <| B.str <| Errors.firstLine (eTitle err) (eMessage err)
        ]


------- ATTR MAP

attributeMap :: Model -> AttrMap
attributeMap _ =
    B.attrMap
        V.defAttr
        [ (B.attrName "good", B.fg V.green)
        , (B.attrName "path", B.fg V.cyan)
        ]


------- EVENT

handleEvent :: Model -> BrickEvent Name Msg -> EventM Name (Next Model)
handleEvent model event =
    case event of
        BT.MouseDown name button _ _ ->
            case name of
                AppViewport ->
                    case button of
                        V.BScrollUp -> do
                            B.vScrollBy (B.viewportScroll AppViewport) (-3)
                            B.continue model
                        V.BScrollDown -> do
                            B.vScrollBy (B.viewportScroll AppViewport) 3
                            B.continue model
                        _ -> B.continue model
                ErrorAt path i ->
                    B.continue
                        <| case mStatus model of
                            Errors errors expandedPaths expandedErrors ->
                                model
                                    { mStatus =
                                        Errors
                                            errors
                                            expandedPaths
                                            (toggle (path, i) expandedErrors)
                                    }
                            _ -> model
                File path ->
                    B.continue
                        <| case mStatus model of
                            Errors errors expandedPaths expandedErrors ->
                                model
                                    { mStatus =
                                        Errors
                                            errors
                                            (toggle path expandedPaths)
                                            expandedErrors
                                    }
                            _ -> model
        BT.VtyEvent ve ->
            case ve of
                V.EvKey V.KEsc [] -> B.halt model
                V.EvKey (V.KChar 'q') [] -> B.halt model
                V.EvKey (V.KChar 'c') [V.MCtrl] -> B.halt model
                _ -> B.continue model
        BT.AppEvent ve ->
            case ve of
                RecompileStarted filepath ->
                    B.continue <| model{mStatus = Compiling filepath}
                GotElmMakeOutput (exitCode, _, stderr) ->
                    B.continue
                        <| model
                            { mStatus =
                                if exitCode == ExitSuccess
                                    then AllGood
                                    else case Errors.fromElmMakeStderr stderr of
                                        Left jsonError ->
                                            CouldntParseElmMakeOutput jsonError
                                        Right errors ->
                                            let paths =
                                                    errors
                                                        |> List.map fPath
                                                        |> Set.fromList
                                             in Errors errors paths Set.empty
                            }
        _ -> B.continue model


toggle :: Ord a => a -> Set a -> Set a
toggle a set =
    if Set.member a set
        then Set.delete a set
        else Set.insert a set
