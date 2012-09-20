module Engine where

import Graphics.UI.Gtk.WebKit.WebView
       (webViewNew, webViewGetDomDocument)
import Graphics.UI.Gtk.WebKit.DOM.Document
       (documentCreateElement, documentGetElementById, documentGetBody)
import Graphics.UI.Gtk.WebKit.DOM.HTMLElement
       (htmlElementInsertAdjacentElement, htmlElementSetInnerHTML,
        htmlElementInsertAdjacentHTML)
import Graphics.UI.Gtk.WebKit.Types (castToHTMLElement, Document,
        HTMLElement, ElementClass, MouseEventClass)
import Control.Applicative ((<$>))
import Control.Arrow
import Control.Monad.Trans ( liftIO )
import Graphics.UI.Gtk.General.Enums (WindowPosition(..))
import Graphics.UI.Gtk.WebKit.DOM.Element
import Graphics.UI.Gtk.WebKit.DOM.EventM
import Graphics.UI.Gtk.WebKit.DOM.Node
import Control.Monad
import Control.Monad.State.Strict
import Data.IORef

import FRP.Sodium
import Game

-- Convert (game) world to/from screen co-ordinates.
-- World co-ordinates are x = -1400..1400, y = -1000 to 1000
-- Screen co-ordinates are x = 0..700, y = 0..500
-- Y is inverted
scale = 1/4
worldLeft = -1400
worldTop  = 1000
toWorld (x,y) = (x / scale + worldLeft, worldTop - y / scale)
fromWorldRect ((xOrig,yOrig),(wid,hei)) = (
        (
            (left - worldLeft) * scale,
            (worldTop - top) * scale
        ),
        (
            wid * scale * 2,
            hei * scale * 2
        )
    )
  where
    left = xOrig - wid
    top  = yOrig + hei

-- | Get the mouse position in world co-ordinates relative to the top-left corner of
-- the specified HTML element.
getXYRelativeTo :: (ElementClass elt, MouseEventClass e) =>
                   elt -> EventM e t (Double, Double) 
getXYRelativeTo container = do
    (x0, y0) <- mouseClientXY
    liftIO $ do
        top <- elementGetOffsetTop container
        left <- elementGetOffsetLeft container
        return $ toWorld $ (fromIntegral *** fromIntegral) (x0 - left, y0 - top)

-- The game logic expects alternating down-up-down-up, but the browser can produce
-- bad sequences like down-up-down-down-up. So we sanitize the input.
mkSanitize :: Eq state =>
              state          -- ^ Initial state
           -> IO (state -> IO () -> IO ())
mkSanitize initialState = do
    stateRef <- newIORef initialState
    return $ \newState action -> do
        oldState <- readIORef stateRef
        when (oldState /= newState) $ do
            writeIORef stateRef newState
            action

data ButtonState = Up | Down deriving Eq

-- | Instantiate the game, handling mouse events and drawing the output.
-- Returns an \'unlisten\' action to de-register listeners.
engine :: ElementClass elt =>
          Document -> elt -> (Event MouseEvent -> Reactive (BehaviorTree [Sprite])) -> IO (IO ()) 
engine doc container game = do
    -- Construct a mouse event that lives in FRP land, and a push action
    -- that allows us to push values into it from IO land.
    (eMouse, pushMouse) <- sync newEvent

    sanitize <- mkSanitize Up

    -- Listen to mouse events from WebKit
    elementOnmousedown container $ do
        xy <- getXYRelativeTo container
        liftIO $ sanitize Down $ sync $ pushMouse $ MouseDown xy
    elementOnmousemove container $ do
        xy <- getXYRelativeTo container
        liftIO $ sync $ pushMouse $ MouseMove xy
    elementOnmouseup container $ do
        xy <- getXYRelativeTo container
        liftIO $ sanitize Up $ sync $ pushMouse $ MouseUp xy

    -- Instantiate the FRP logic: We give it our mouse event, and it gives us back the
    -- sprite behaviours that tell us what to draw on the screen.
    sprites <- sync (game eMouse)

    -- Add listeners to the sprite behaviours so the FRP output gets drawn on the
    -- web page.
    showAll doc container sprites

showAll :: ElementClass elt =>
             Document -> elt -> BehaviorTree [Sprite] -> IO (IO ())
showAll doc container sprites =
    -- Pass the zIndex through as state. The order of the FRP's output determines
    -- what overlaps what. Later elements overlap earlier ones. In CSS this is
    -- drawn correctly by setting the zIndex.
    evalStateT (showEach sprites) (-1000000)
  where
    showEach :: BehaviorTree [Sprite] -> StateT Int IO (IO ())
    showEach (left :++ right) = do
        -- Traverse the tree structure
        unlisten1 <- showEach left
        unlisten2 <- showEach right
        -- Collect event unlisteners.
        return (unlisten1 >> unlisten2)
    showEach (BehaviorNode beh) = do
        -- Each behaviour outputs a list of sprites. For each behaviour we
        -- pre-allocate 1000 zIndex numbers to allow for expansion of the
        -- sprite list per behaviour.
        zIxRoot <- get
        modify (1000+)
        liftIO $ do
            -- Remember the behaviour's last value
            lastRef <- newIORef []
            -- Listen to changes in the value of the behaviour (a list of sprites)
            unlisten <- sync $ listen (values beh) $ \these -> do
                last <- readIORef lastRef
                let toAdd = drop (length last) these
                    toRemove = drop (length these) (map fst last)
                    toModify = zip these last
                    keptSpans = map (\(_, (elt, _)) -> elt) toModify
                    noOfKeptSpans = length keptSpans
                -- If there are fewer elements than last time, we delete the excess ones.
                mapM_ (nodeRemoveChild container . Just) toRemove
                -- If the first n sprites exist in both the old and new list, we
                -- re-use them, and just modify their position and appearance as necessary
                sequence_ $ zipWith (\zIx (newSprite, (elt, oldSprite)) -> do
                        let (oldRect, oldFn) = oldSprite
                            (newRect, newFn) = newSprite
                        when (oldRect /= newRect) $ position  elt newRect zIx
                        when (oldFn /= newFn)     $ associate elt newFn
                    ) [zIxRoot..] toModify
                -- If there are more elements than last time, we create the new ones
                addedSpans <- sequence $ zipWith (\zIx sprite@(rect, fn) -> do
                        Just elt <- fmap castToHTMLElement <$> documentCreateElement doc "img"
                        position elt rect zIx
                        associate elt fn
                        elementSetAttribute elt "draggable" "false"
                        nodeAppendChild container (Just elt)
                        return elt
                    ) [zIxRoot + noOfKeptSpans..] toAdd
                writeIORef lastRef (zip (keptSpans ++ addedSpans) these)
            return unlisten
    -- Set the necessary attributes to position the image according to the specified
    -- rectangle
    position elt rect zIx = do
        elementSetAttribute elt "style" (style origin zIx)
        elementSetAttribute elt "width" (show wid)
        elementSetAttribute elt "height" (show hei)
      where
        (origin, (wid, hei)) = fromWorldRect rect
        style (x, y) zIx = "position:absolute;top:"++show y
                                    ++"px;left:"++show x
                                  ++"px;zIndex:"++show zIx
                                  ++disableTextSelection
        -- See http://stackoverflow.com/questions/826782/css-rule-to-disable-text-selection-highlighting
        disableTextSelection =
            "-webkit-touch-callout:none;"++
            "-webkit-user-select: none;"++
            "-khtml-user-select: none;"++
            "-moz-user-select: none;"++
            "-ms-user-select: none;"++
            "user-select: none"
    -- Associate the image element with a URL, i.e. set its appearance.
    associate elt fn =
        elementSetAttribute elt "src" ("http://hip-to-be-square.com/~blackh/"++fn)
