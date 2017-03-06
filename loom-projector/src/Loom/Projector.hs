{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Loom.Projector (
    ProjectorError (..)
  , ProjectorHaskellError (..)
  , ProjectorInterpretError (..)
  , ProjectorInput (..)
  , ProjectorOutput
  , MachinatorModules
  , projectorOutputModules
  , projectorOutputModuleExprs
  , DataModuleName (..)
  , ModuleName (..)
  , Projector.Html (..)
  , Projector.Attribute (..)
  , compileProjector
  , generateProjectorHtml
  , generateProjectorHaskell
  , moduleNameFromFile
  , requiredProjectorHaskellImports
  , renderProjectorError
  , renderProjectorHaskellError
  , renderProjectorInterpretError
  ) where

import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Catch (handleIf)

import           Data.List (stripPrefix)
import           Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Text.IO as T

import qualified Machinator.Core as MC

import           P

import           Projector.Html (DataModuleName (..), ModuleName (..), HtmlExpr, HtmlType)
import           Projector.Html.Data.Annotation (SrcAnnotation)
import qualified Projector.Html as Projector
import qualified Projector.Html.Core.Machinator as Projector
import qualified Projector.Html.Data.Backend as Projector
import qualified Projector.Html.Data.Module as Projector
import qualified Projector.Html.Interpreter as Projector
import qualified Projector.Core as Projector

import           System.Directory (createDirectoryIfMissing)
import           System.FilePath (FilePath, (</>), takeDirectory, joinPath)
import           System.IO (IO)
import           System.IO.Error (isDoesNotExistError)

import           X.Control.Monad.Trans.Either (EitherT, newEitherT, hoistEither)

data ProjectorError =
    ProjectorFileMissing FilePath
  | ProjectorError [Projector.HtmlError]
    deriving (Eq, Show)

data ProjectorHaskellError =
    ProjectorHaskellError Projector.HtmlError
  deriving (Eq, Show)

data ProjectorInterpretError =
    ProjectorInterpretError (Projector.InterpretError (HtmlType, SrcAnnotation))
  deriving (Eq, Show)

data ProjectorInput =
  ProjectorInput {
      projectorModuleName :: ModuleName
    , projectorModuleRoot :: FilePath
    , projectorModuleTemplates :: [FilePath]
    } deriving (Show)

data ProjectorOutput =
  ProjectorOutput {
      -- FIX Expose the correct HtmlModules type
      _projectorOutputArtefacts :: Projector.BuildArtefacts
    }

instance Monoid ProjectorOutput where
  mempty =
    ProjectorOutput (Projector.BuildArtefacts mempty mempty)
  mappend (ProjectorOutput (Projector.BuildArtefacts _ d1)) (ProjectorOutput (Projector.BuildArtefacts _ d2)) =
    ProjectorOutput (Projector.BuildArtefacts mempty (d1 <> d2))

projectorOutputModules :: ProjectorOutput -> [ModuleName]
projectorOutputModules (ProjectorOutput (Projector.BuildArtefacts _ ms)) =
  Map.keys ms

projectorOutputModuleExprs ::
  ProjectorOutput ->
  Map ModuleName [HtmlExpr (HtmlType, SrcAnnotation)]
projectorOutputModuleExprs (ProjectorOutput (Projector.BuildArtefacts _ ms)) =
  fmap (fmap snd . Map.elems . Projector.moduleExprs) $ ms

-- FIX Should be in machinator
type MachinatorModules = Map.Map Projector.DataModuleName [MC.Definition]

compileProjector ::
  MachinatorModules ->
  ProjectorOutput ->
  ProjectorInput ->
  EitherT ProjectorError IO ProjectorOutput
compileProjector
  udts
  (ProjectorOutput (Projector.BuildArtefacts _ oh1))
  (ProjectorInput prefix root inputs) = do

  templates <- for inputs $ \input ->
    fmap ((,) (moduleNameFromFile . fromMaybe input . stripPrefix root $ input)) .
      newEitherT . fmap (maybeToRight (ProjectorFileMissing input)) . readFileSafe $
        input
  let
    decls =
      Projector.machinatorDecls . join . Map.elems $ udts
  Projector.BuildArtefacts _ oh2 <- firstT ProjectorError . hoistEither $
    Projector.runBuildIncremental
      (Projector.Build
        -- FIX Remove backend compiling from runBuildIncremental
        Nothing
        (Projector.moduleNamerSimple (Just prefix))
        (Map.keys udts)
        )
      (Projector.UserDataTypes decls)
      oh1
      (Projector.RawTemplates . fmap (first (moduleNameToFile "prj")) $ templates)
  hoistEither . first ProjectorError $
    Projector.warnModules decls oh2
  pure $ ProjectorOutput (Projector.BuildArtefacts mempty oh2)

generateProjectorHtml ::
  MachinatorModules ->
  ProjectorOutput ->
  Projector.HtmlExpr (HtmlType, SrcAnnotation) ->
  Either ProjectorInterpretError Projector.Html
generateProjectorHtml mo (ProjectorOutput (Projector.BuildArtefacts _ h)) =
  first ProjectorInterpretError . Projector.interpret
    (Projector.machinatorDecls . join $ Map.elems mo)
    (Projector.extractModuleExprs h)

generateProjectorHaskell :: FilePath -> ProjectorOutput -> EitherT ProjectorHaskellError IO [FilePath]
generateProjectorHaskell output (ProjectorOutput (Projector.BuildArtefacts _ oh2)) =
  for (Map.toList oh2) $ \(n, m) -> do
    let
      f = moduleNameToFile "hs" n
    -- TODO validateModules
    -- https://github.com/ambiata/projector/blob/master/projector-html/src/Projector/Html.hs#L216
    (_, t) <- hoistEither . first ProjectorHaskellError $
      Projector.codeGenModule Projector.Haskell n m
    liftIO $
      createDirectoryIfMissing True (output </> takeDirectory f)
    liftIO $
      T.writeFile (output </> f) t
    pure f

moduleNameFromFile :: FilePath -> ModuleName
moduleNameFromFile =
  Projector.pathToModuleName (Projector.moduleNamerSimple Nothing)

moduleNameToFile :: FilePath -> ModuleName -> FilePath
moduleNameToFile ext (ModuleName n) =
  (joinPath . fmap T.unpack . T.splitOn ".") n <> "." <> ext

requiredProjectorHaskellImports :: [ModuleName]
requiredProjectorHaskellImports =
  [
      Projector.htmlRuntime
    ]

renderProjectorError :: ProjectorError -> Text
renderProjectorError pe =
  case pe of
    ProjectorFileMissing f ->
      "Could not find file: " <> T.pack f
    ProjectorError es ->
      "Projector build errors:\n" <> T.unlines (fmap Projector.renderHtmlError es)

renderProjectorHaskellError :: ProjectorHaskellError -> Text
renderProjectorHaskellError pe =
  case pe of
    ProjectorHaskellError e ->
      Projector.renderHtmlError e

renderProjectorInterpretError :: ProjectorInterpretError -> Text
renderProjectorInterpretError pe =
  case pe of
    ProjectorInterpretError (Projector.InterpretInvalidExpression e) ->
      -- FIX Better error message from projector
      "Error interpretting expression:\n" <> Projector.ppExpr e

-- FIX Common module?
readFileSafe :: MonadIO m => FilePath -> m (Maybe Text)
readFileSafe =
  liftIO . handleIf isDoesNotExistError (const $ pure Nothing) . fmap Just . T.readFile
